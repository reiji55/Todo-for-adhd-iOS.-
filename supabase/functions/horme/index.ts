// Supabase Edge Function: /functions/v1/horme/<HORME_KEY>/sync for the app, /mcp for Claude.
// The key in the path is the only credential, like the task-3days connector; a wrong key answers 404.
// Deploy with JWT verification off (the path key replaces it).

import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { handleMcp } from "./tools.ts";
import type { RecordStore } from "./tools.ts";
import type { SyncRecord } from "./records.ts";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const store: RecordStore = {
  async load() {
    const { data, error } = await supabase.from("horme_records").select("payload");
    if (error) throw new Error(error.message);
    return (data ?? []).map((row: { payload: SyncRecord }) => row.payload);
  },
  async merge(changes) {
    const { error } = await supabase.rpc("horme_merge", { incoming: changes });
    if (error) throw new Error(error.message);
  },
};

function sameSecret(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const parts = new URL(req.url).pathname.split("/").filter(Boolean);
  const at = parts.indexOf("horme");
  const [key, route] = [parts[at + 1] ?? "", parts[at + 2] ?? ""];
  if (!sameSecret(key, Deno.env.get("HORME_KEY") ?? "")) return json({ error: "not found" }, 404);

  if (route === "sync") {
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    try {
      const body = await req.json();
      const records: SyncRecord[] = Array.isArray(body?.records) ? body.records : [];
      if (records.length) await store.merge(records);
      return json({ records: await store.load() });
    } catch (e) {
      return json({ error: String((e as Error).message ?? e) }, 400);
    }
  }

  if (route === "mcp") {
    if (req.method === "GET") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    if (req.method === "DELETE") return new Response(null, { status: 204 });
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    let body: any;
    try { body = await req.json(); } catch { return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }, 400); }
    const messages = Array.isArray(body) ? body : [body];
    const replies = (await Promise.all(messages.map((m) => handleMcp(m, store)))).filter((r) => r !== null);
    if (!replies.length) return new Response(null, { status: 202 });
    return json(Array.isArray(body) ? replies : replies[0]);
  }

  return json({ error: "not found" }, 404);
});
