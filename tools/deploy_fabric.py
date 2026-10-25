"""
Deploy the Bank Reconciliation backend to Microsoft Fabric using your Azure CLI login (az login).

    python tools/deploy_fabric.py items      # create (or find) lakehouse + warehouse
    python tools/deploy_fabric.py upload     # upload Excel + Parquet to Files/, load Delta tables
    python tools/deploy_fabric.py sql        # run sql/*.sql against the warehouse
    python tools/deploy_fabric.py notebook   # build + import/update the notebook
    python tools/deploy_fabric.py run        # run the notebook once and wait
    python tools/deploy_fabric.py all

Settings come from env vars or the defaults below.
"""
import base64
import json
import os
import re
import struct
import sys
import time
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

WORKSPACE_ID = os.getenv("FABRIC_WORKSPACE_ID", "290f6b06-3796-4928-9d58-f562fd0bfecd")  # Dynatech_MDM_Bronze
LAKEHOUSE = os.getenv("FABRIC_LAKEHOUSE", "LH_BankRecon")
WAREHOUSE = os.getenv("FABRIC_WAREHOUSE", "WH_BankRecon")
NOTEBOOK = os.getenv("FABRIC_NOTEBOOK", "nb_bank_recon_match")
FILES_DIR = "bank_recon"          # Files/bank_recon/raw (Excel) and Files/bank_recon/parquet
TABLES = {"jde_f09617_bank_statement": "Bank Statement Detail F09617 July 1 - Sept 11 2026.xlsx",
          "jde_f0911_gl": "GL F0911 All Bank Accts May 1 - Sept 11 2026.xlsx"}

API = "https://api.fabric.microsoft.com/v1"
ONELAKE = "https://onelake.dfs.fabric.microsoft.com"
_cred = AzureCliCredential(process_timeout=60)   # first az call of the day can be slow


def token(scope: str) -> str:
    return _cred.get_token(scope).token


def fabric(method: str, path: str, **kw):
    h = {"Authorization": f"Bearer {token('https://api.fabric.microsoft.com/.default')}"}
    r = requests.request(method, f"{API}{path}", headers=h, **kw)
    if r.status_code == 202:                       # long-running operation
        loc = r.headers.get("Location")
        while loc:
            time.sleep(int(r.headers.get("Retry-After", 3)))
            r = requests.get(loc, headers=h)
            body = r.json() if r.content else {}
            status = body.get("status")
            if status in ("Succeeded", "Completed"):
                res = requests.get(loc + "/result", headers=h)
                return res.json() if res.ok and res.content else body
            if status in ("Failed", "Cancelled"):
                raise RuntimeError(f"{method} {path} failed: {body}")
            if r.status_code == 200 and status is None:
                return body
        return {}
    if not r.ok:
        raise RuntimeError(f"{method} {path} -> {r.status_code}: {r.text}")
    return r.json() if r.content else {}


def find_item(item_type: str, name: str):
    for it in fabric("GET", f"/workspaces/{WORKSPACE_ID}/items", params={"type": item_type}).get("value", []):
        if it["displayName"] == name:
            return it
    return None


def ensure_item(item_type: str, name: str, endpoint: str, description: str):
    it = find_item(item_type, name)
    if it:
        print(f"{item_type} '{name}' exists: {it['id']}")
        return it
    fabric("POST", f"/workspaces/{WORKSPACE_ID}/{endpoint}", json={"displayName": name, "description": description})
    for _ in range(20):
        it = find_item(item_type, name)
        if it:
            print(f"{item_type} '{name}' created: {it['id']}")
            return it
        time.sleep(3)
    raise RuntimeError(f"{item_type} {name} not found after create")


def cmd_items():
    lh = ensure_item("Lakehouse", LAKEHOUSE, "lakehouses", "Bank reconciliation - JDE F09617/F0911 test data")
    wh = ensure_item("Warehouse", WAREHOUSE, "warehouses", "Bank reconciliation - proposals, review, audit, JDE output")
    return lh, wh


def onelake_put(rel_path: str, data: bytes):
    """Upload one file to OneLake via the ADLS Gen2 DFS API (create -> append -> flush)."""
    lh = find_item("Lakehouse", LAKEHOUSE)
    url = f"{ONELAKE}/{WORKSPACE_ID}/{lh['id']}/{rel_path}"
    h = {"Authorization": f"Bearer {token('https://storage.azure.com/.default')}", "x-ms-version": "2023-11-03"}
    for step, params, body in (("create", {"resource": "file"}, None),
                               ("append", {"action": "append", "position": 0}, data),
                               ("flush", {"action": "flush", "position": len(data)}, None)):
        r = requests.request("PUT" if step == "create" else "PATCH", url, params=params, data=body, headers=h)
        if not r.ok:
            raise RuntimeError(f"OneLake {step} {rel_path}: {r.status_code} {r.text}")
    print(f"  uploaded {rel_path} ({len(data):,} bytes)")


def cmd_upload():
    import prepare_test_data
    prepare_test_data.main()
    lh = find_item("Lakehouse", LAKEHOUSE)
    for table, xlsx in TABLES.items():
        onelake_put(f"Files/{FILES_DIR}/raw/{xlsx}", (ROOT / xlsx).read_bytes())
        onelake_put(f"Files/{FILES_DIR}/parquet/{table}.parquet", (ROOT / "test_data" / f"{table}.parquet").read_bytes())
        fabric("POST", f"/workspaces/{WORKSPACE_ID}/lakehouses/{lh['id']}/tables/{table}/load",
               json={"relativePath": f"Files/{FILES_DIR}/parquet/{table}.parquet", "pathType": "File",
                     "mode": "Overwrite", "formatOptions": {"format": "Parquet"}})
        print(f"  loaded table {table}")


def wh_connect():
    import pyodbc
    wh = fabric("GET", f"/workspaces/{WORKSPACE_ID}/warehouses/{find_item('Warehouse', WAREHOUSE)['id']}")
    server = wh["properties"]["connectionString"]
    tok = token("https://database.windows.net/.default").encode("utf-16-le")
    attrs = {1256: struct.pack(f"<I{len(tok)}s", len(tok), tok)}   # SQL_COPT_SS_ACCESS_TOKEN
    return pyodbc.connect(f"Driver={{ODBC Driver 18 for SQL Server}};Server={server},1433;Database={WAREHOUSE};"
                          "Encrypt=yes;TrustServerCertificate=no", attrs_before=attrs, autocommit=True)


def run_sql_file(cur, path: Path):
    batches = [b.strip() for b in re.split(r"^\s*GO\s*$", path.read_text(encoding="utf-8"), flags=re.M | re.I)]
    for b in batches:
        if b and re.sub(r"/\*.*?\*/|--[^\n]*", "", b, flags=re.S).strip():
            cur.execute(b)
    print(f"  ran {path.name} ({len(batches)} batches)")


def cmd_sql():
    with wh_connect() as cn:
        cur = cn.cursor()
        for f in sorted((ROOT / "sql").glob("0[0-9]_*.sql")):   # setup scripts only (99_ = checks)
            run_sql_file(cur, f)


def cmd_notebook():
    import build_notebook
    lh = find_item("Lakehouse", LAKEHOUSE)
    nb_path = build_notebook.build(ROOT / "notebooks" / f"{NOTEBOOK}.ipynb", {
        "__SOURCE_WORKSPACE_ID__": WORKSPACE_ID, "__SOURCE_ITEM_ID__": lh["id"], "__SOURCE_PROFILE__": "test",
        "__WAREHOUSE_NAME__": WAREHOUSE})
    payload = base64.b64encode(nb_path.read_bytes()).decode()
    definition = {"format": "ipynb", "parts": [
        {"path": "notebook-content.ipynb", "payload": payload, "payloadType": "InlineBase64"}]}
    nb = find_item("Notebook", NOTEBOOK)
    if nb:
        fabric("POST", f"/workspaces/{WORKSPACE_ID}/notebooks/{nb['id']}/updateDefinition", json={"definition": definition})
        print(f"Notebook '{NOTEBOOK}' updated: {nb['id']}")
    else:
        fabric("POST", f"/workspaces/{WORKSPACE_ID}/notebooks",
               json={"displayName": NOTEBOOK, "description": "Bank reconciliation matching run", "definition": definition})
        print(f"Notebook '{NOTEBOOK}' created: {find_item('Notebook', NOTEBOOK)['id']}")


def cmd_run(params: dict | None = None):
    nb = find_item("Notebook", NOTEBOOK)
    body = {"executionData": {"parameters": {k: {"value": v, "type": "string"} for k, v in (params or {}).items()}}}
    h = {"Authorization": f"Bearer {token('https://api.fabric.microsoft.com/.default')}"}
    r = requests.post(f"{API}/workspaces/{WORKSPACE_ID}/items/{nb['id']}/jobs/instances?jobType=RunNotebook",
                      headers=h, json=body)
    if r.status_code != 202:
        raise RuntimeError(f"run failed to start: {r.status_code} {r.text}")
    loc = r.headers["Location"]
    print("Started job", loc.rsplit("/", 1)[-1])
    while True:
        time.sleep(15)
        j = requests.get(loc, headers={"Authorization": f"Bearer {token('https://api.fabric.microsoft.com/.default')}"}).json()
        print("  status:", j.get("status"))
        if j.get("status") in ("Completed", "Failed", "Cancelled", "Deduped"):
            if j.get("failureReason"):
                print(json.dumps(j["failureReason"], indent=2))
            return j


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    steps = {"items": cmd_items, "upload": cmd_upload, "sql": cmd_sql, "notebook": cmd_notebook, "run": cmd_run}
    for name in (steps if what == "all" else [what]):
        print(f"== {name}")
        steps[name]()
