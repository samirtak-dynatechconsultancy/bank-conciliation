import { NextResponse } from "next/server";

/** JSON response; errors are logged server-side and returned without internals. */
export async function handle(fn: () => Promise<unknown>) {
  try {
    return NextResponse.json(await fn(), { headers: { "Cache-Control": "no-store" } });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(message);
    const friendly = /Missing environment variable/.test(message)
      ? message
      : /fetch failed|ENOTFOUND|ECONNRESET/i.test(message)
        ? "Could not reach Microsoft sign-in (login.microsoftonline.com) - network problem, please try again."
        : /AADSTS/i.test(message)
          ? "The client secret was rejected by Entra ID - check RECON_CLIENT_SECRET (expired or wrong)."
          : /Login failed|authentication failed/i.test(message)
            ? "Fabric rejected the sign-in. Right after granting access this can take 15-30 minutes - try again; " +
              "otherwise check the app's Viewer access on both workspaces."
            : /socket hang up|Connection lost|ETIMEOUT/i.test(message)
              ? "The connection to Fabric was dropped (network) - please try again."
              : "Query failed - see the server logs for details.";
    return NextResponse.json({ error: friendly }, { status: 500 });
  }
}
