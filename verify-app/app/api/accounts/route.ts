import { getAccounts } from "@/lib/recon";
import { handle } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  return handle(() => getAccounts());
}
