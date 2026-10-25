import sql from "mssql";

/**
 * Two connections, both as the service principal (client credentials):
 *   warehouse -> dbo.bank_recon_* (matching results)
 *   lakehouse -> proddta.* (JDE source rows, SQL analytics endpoint)
 *
 * Sign-in: we request the Entra ID token ourselves (client credentials, scope database.windows.net) and pass it
 * to the driver as an access token. The driver's built-in "service-principal-secret" flow fails against Fabric
 * ("authentication failed"); this path is the one proven by scripts/diagnose.mjs.
 * A token lives ~60-90 min: it is cached and renewed 5 min before expiry; pools are re-created with the new token.
 */
export type Target = "warehouse" | "lakehouse";

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing environment variable ${name}`);
  return v;
}

type Token = { value: string; expiresAt: number };
type PoolEntry = { token: string; pool: Promise<sql.ConnectionPool> };
const g = globalThis as unknown as { __token?: Promise<Token>; __pools?: Partial<Record<Target, PoolEntry>> };
g.__pools ??= {};

async function fetchToken(): Promise<Token> {
  const res = await fetch(`https://login.microsoftonline.com/${required("RECON_TENANT_ID")}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: required("RECON_CLIENT_ID"),
      client_secret: required("RECON_CLIENT_SECRET"),
      scope: "https://database.windows.net/.default",
    }),
    cache: "no-store",
  });
  const body = (await res.json()) as { access_token?: string; expires_in?: number; error?: string; error_description?: string };
  if (!body.access_token) {
    throw new Error(`AADSTS token request failed: ${body.error ?? res.status} ${String(body.error_description ?? "").split("\r\n")[0]}`);
  }
  return { value: body.access_token, expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000 };
}

/** Cached token; renewed 5 minutes before it expires. */
async function token(): Promise<string> {
  const current = g.__token ? await g.__token.catch(() => null) : null;
  if (!current || current.expiresAt - Date.now() < 5 * 60_000) {
    g.__token = fetchToken();
    g.__token.catch(() => { g.__token = undefined; });   // retry on the next request
  }
  return (await g.__token!).value;
}

function config(target: Target, accessToken: string): sql.config {
  const prefix = target === "warehouse" ? "WAREHOUSE" : "LAKEHOUSE";
  return {
    server: required(`${prefix}_SERVER`),
    database: required(`${prefix}_DATABASE`),
    port: 1433,
    authentication: { type: "azure-active-directory-access-token", options: { token: accessToken } },
    options: { encrypt: true, trustServerCertificate: false },
    connectionTimeout: 30_000,
    requestTimeout: 120_000,
    pool: { max: 4, min: 0, idleTimeoutMillis: 60_000 },
  };
}

async function pool(target: Target): Promise<sql.ConnectionPool> {
  const accessToken = await token();
  const entry = g.__pools![target];
  if (entry && entry.token === accessToken) return entry.pool;

  // new or renewed token -> new pool (connections of the old pool would sign in with the old token)
  if (entry) entry.pool.then((p) => p.close()).catch(() => {});
  const created = new sql.ConnectionPool(config(target, accessToken)).connect();
  g.__pools![target] = { token: accessToken, pool: created };
  created.catch(() => {
    if (g.__pools![target]?.pool === created) delete g.__pools![target];   // retry on the next request
  });
  return created;
}

export type Params = Record<string, string | number | null | undefined>;

/** Temporary failures worth one retry: sign-in rejected while Fabric permissions propagate, dropped connection,
 *  or the token endpoint briefly unreachable ("fetch failed"). */
function isTransient(err: unknown): boolean {
  const e = err as { code?: string; message?: string; cause?: unknown };
  return ["ELOGIN", "ESOCKET", "ETIMEOUT", "ECONNCLOSED", "ECONNRESET"].includes(e?.code ?? "")
    || /fetch failed|authentication failed|socket hang up|Connection lost/i.test(e?.message ?? "");
}

function reset(target: Target, dropToken: boolean) {
  const entry = g.__pools![target];
  if (entry) entry.pool.then((p) => p.close()).catch(() => {});
  delete g.__pools![target];
  if (dropToken) g.__token = undefined;
}

/** Run a read-only query with named parameters (@name). Values are always sent as parameters, never concatenated.
 *  Retries once (fresh connection, fresh token) on a temporary failure. */
export async function query<T = Record<string, unknown>>(target: Target, text: string, params: Params = {}): Promise<T[]> {
  try {
    return await runQuery<T>(target, text, params);
  } catch (err) {
    if (!isTransient(err)) throw err;
    console.warn(`[${target}] temporary failure, retrying once: ${(err as Error).message}`);
    reset(target, true);
    await new Promise((r) => setTimeout(r, 2000));
    return runQuery<T>(target, text, params);
  }
}

async function runQuery<T>(target: Target, text: string, params: Params): Promise<T[]> {
  const request = (await pool(target)).request();
  for (const [name, value] of Object.entries(params)) {
    // varchar, not nvarchar: Fabric Warehouse stores text as varchar (UTF-8)
    if (value === undefined || value === null || value === "") request.input(name, sql.VarChar(4000), null);
    else if (typeof value === "number") request.input(name, Number.isInteger(value) ? sql.BigInt : sql.Decimal(18, 2), value);
    else request.input(name, sql.VarChar(4000), value);
  }
  const result = await request.query(text);
  return result.recordset as T[];
}
