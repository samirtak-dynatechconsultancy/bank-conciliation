/**
 * Connection diagnostics for Recon Verify. Prints each stage; never prints the secret.
 *   node scripts/diagnose.mjs
 * Stage 1: Entra token for the service principal (proves tenant / client id / secret)
 * Stage 2: SQL connection + sign-in to the warehouse, then the lakehouse, with tedious debug messages
 * Stage 3: SELECT 1 + a count from each side
 */
import fs from "node:fs";
import sql from "mssql";

// --- load .env.local (dev) or .env (portable package) without extra packages ---
const env = {};
const envFile = [new URL("../.env.local", import.meta.url), new URL("../.env", import.meta.url)].find((f) => fs.existsSync(f));
if (!envFile) { console.log("✗ No .env.local or .env found next to the app"); process.exit(1); }
for (const line of fs.readFileSync(envFile, "utf8").split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
}
const need = ["RECON_TENANT_ID", "RECON_CLIENT_ID", "RECON_CLIENT_SECRET", "WAREHOUSE_SERVER", "WAREHOUSE_DATABASE",
              "LAKEHOUSE_SERVER", "LAKEHOUSE_DATABASE"];
for (const k of need) if (!env[k]) { console.log(`✗ ${k} is empty in the .env file`); process.exit(1); }
console.log(`Node ${process.version}`);

// --- Stage 1: token ---
console.log("\n[1] Entra ID token for the service principal …");
const tokRes = await fetch(`https://login.microsoftonline.com/${env.RECON_TENANT_ID}/oauth2/v2.0/token`, {
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({
    grant_type: "client_credentials", client_id: env.RECON_CLIENT_ID, client_secret: env.RECON_CLIENT_SECRET,
    scope: "https://database.windows.net/.default",
  }),
});
const tok = await tokRes.json();
if (!tok.access_token) {
  console.log(`✗ No token: ${tok.error} – ${String(tok.error_description).split("\r\n")[0]}`);
  console.log("  -> wrong tenant id / client id / secret, or the secret has expired.");
  process.exit(1);
}
console.log("✓ Token received (tenant, client id and secret are correct)");

// --- Stage 2 + 3: SQL ---
async function trySql(label, server, database) {
  console.log(`\n[2] ${label}: connect + sign in to ${server} / ${database} …`);
  const pool = new sql.ConnectionPool({
    server, database, port: 1433,
    authentication: { type: "azure-active-directory-access-token", options: { token: tok.access_token } },
    options: { encrypt: true, trustServerCertificate: false, debug: { packet: false, data: false, payload: false, token: false, log: true } },
    connectionTimeout: 30000, requestTimeout: 60000,
  });
  const log = [];
  pool.on("error", (e) => log.push(`pool error: ${e.message}`));
  try {
    await pool.connect();
    console.log("✓ Signed in");
    const r = await pool.request().query("SELECT DB_NAME() AS db, SUSER_SNAME() AS signed_in_as, @@VERSION AS version");
    console.log(`✓ [3] Query OK – database ${r.recordset[0].db}, signed in as ${r.recordset[0].signed_in_as}`);
    return true;
  } catch (e) {
    console.log(`✗ ${e.code ?? ""} ${e.message}`);
    if (e.originalError) console.log(`  inner: ${e.originalError.message}`);
    if (/Login failed|not have permission|Cannot open database/i.test(e.message))
      console.log("  -> the service principal is not allowed: add it to the workspace (Viewer) and enable the tenant setting\n     'Service principals can use Fabric APIs'; also check the database name.");
    if (/socket hang up|ECONNRESET|Connection lost/i.test(e.message))
      console.log("  -> the server closed the connection during encryption / sign-in: usually the service principal is not\n     allowed into Fabric yet (tenant setting / workspace access), or a proxy / VPN interferes with port 1433.");
    return false;
  } finally {
    log.forEach((l) => console.log("  " + l));
    await pool.close().catch(() => {});
  }
}

const w = await trySql("Warehouse", env.WAREHOUSE_SERVER, env.WAREHOUSE_DATABASE);
const l = await trySql("Lakehouse", env.LAKEHOUSE_SERVER, env.LAKEHOUSE_DATABASE);
console.log(`\nResult: warehouse ${w ? "OK" : "FAILED"}, lakehouse ${l ? "OK" : "FAILED"}`);
process.exit(w && l ? 0 : 1);
