# Recon Verify – bank reconciliation verification app

A small, **read-only** web app for functional users. It reads the matching results from the Fabric **Warehouse**
and the JDE source rows from the Fabric **Lakehouse** (two SQL endpoints, possibly in different workspaces) and
compares them automatically.

| Tab | What it does |
|---|---|
| **Matches** | Filter proposals (account, category 1:1 / 1:M / M:1, status, rule, amount). Click one → its warehouse lines, the same lines read live from the lakehouse, and **automatic checks** (lines found, bank total = GL total = proposal, same account, dates within the rule window, reconciled flags vs `recon_state`, 1:M / M:1 shape, 1% part rule). |
| **Line lookup** | Paste a `line_id` → where it appears in the warehouse (match / unmatched / candidate / decision) + its source row. |
| **Totals check** | Per account: did the latest run read every bank and GL source row? |

It only runs `SELECT`s. It never calls a procedure and never writes anything.

## Stack

Next.js 15 (App Router, Node runtime), `mssql` 12 / `tedious` 20 with **Microsoft Entra service principal** authentication
(client credentials). All SQL runs server-side in API routes; the browser never sees credentials. Every page and API
route is behind HTTP Basic auth (`middleware.ts`, fails closed if not configured).

## 1. Service principal: `App_Dynatech_tpsqlscript_send_as`

| Item | Value |
|---|---|
| Client (application) ID | `a25cb75b-c576-45b2-bfa4-057410a4bdc9` |
| Tenant ID | `a88a9022-7c1c-4daf-a188-ffb1564574f7` |
| Client secret | Entra ID → App registrations → the app → **Certificates & secrets** → New client secret. Copy it once; store it **only** in Vercel env vars. |

Fabric needs to let this service principal in:

1. **Tenant setting** (Fabric admin portal → Tenant settings → Developer settings): *"Service principals can use Fabric
   APIs"* enabled for the app (or a security group containing it).
2. **Workspace access** – add the app to **both** workspaces (workspace → Manage access): the warehouse workspace and
   the lakehouse workspace (`f2f8c0b7-…`). **Viewer** is enough for read-only.
   *(Or share only the two items: warehouse with "Read all data using SQL", lakehouse with "Read all SQL endpoint data".)*
3. That's all – the app needs no write permission.

## 2. Configuration (environment variables)

See `.env.example`.

| Variable | Value |
|---|---|
| `RECON_TENANT_ID` | `a88a9022-7c1c-4daf-a188-ffb1564574f7` |
| `RECON_CLIENT_ID` | `a25cb75b-c576-45b2-bfa4-057410a4bdc9` |
| `RECON_CLIENT_SECRET` | the client secret (**secret**) |
| `WAREHOUSE_SERVER` | warehouse SQL connection string (`…datawarehouse.fabric.microsoft.com`) |
| `WAREHOUSE_DATABASE` | warehouse name |
| `LAKEHOUSE_SERVER` | lakehouse **SQL analytics endpoint** connection string (Lakehouse → SQL analytics endpoint → Settings → SQL connection string) |
| `LAKEHOUSE_DATABASE` | lakehouse name |
| `APP_USERNAME` / `APP_PASSWORD` | login for the app's users (**secret**) – share with the functional team only |

## 3. Run locally

```bash
cd verify-app
cp .env.example .env.local      # fill in the values
npm install
npm run dev                     # http://localhost:3000
```

## 4. Deploy to Vercel

1. Push this folder to a Git repository (the `.gitignore` keeps `.env.local` out).
2. Vercel → **Add New Project** → import the repo → **Root Directory: `verify-app`** → Framework: Next.js.
3. **Settings → Environment Variables**: add every variable from section 2 (mark the secret ones as *Sensitive*).
4. Deploy. Open the URL → the browser asks for `APP_USERNAME` / `APP_PASSWORD`.
5. Optional, recommended: **Settings → Deployment Protection** to also restrict access with Vercel Authentication.

Vercel functions connect outbound to Fabric on TCP **1433**. If the client restricts Fabric by network (private
links / IP allow-list), Vercel's dynamic IPs will be blocked – then host the app inside the client network instead.

## 5. Troubleshooting

| Message | Cause |
|---|---|
| "Access is not configured" | `APP_USERNAME` / `APP_PASSWORD` missing |
| "Missing environment variable …" | a variable from section 2 is missing |
| "Could not sign in to Fabric with the service principal" | wrong / expired secret, tenant setting off, or app not added to the workspace |
| "Query failed" | see Vercel → Project → Logs; usually a wrong database name or no access to that item |
| "Connection lost - socket hang up" | Fabric drops sign-ins from the old `tedious` 18 driver. The app pins `mssql` 12.7.4 + `tedious` 20.3.4, which work – do not downgrade. If it still happens, the network blocks SQL sign-in on port 1433 (test with `node scripts/diagnose.mjs`, or from another network). |

## 6. Good to know

- The checks mirror the matching rules: exact amounts to the cent, dates within ±5 days, never both sides `R`,
  1:M / M:1 with 2–5 parts each ≥ 1 % of the single side.
- GL lines are looked up by 6 of the 7 F0911 key parts (Line Extension Code is empty in the client data –
  `OPEN_ISSUES.md` #1).
- Bank line numbers and amounts are shown as stored (×100 / cents) next to the converted values.
