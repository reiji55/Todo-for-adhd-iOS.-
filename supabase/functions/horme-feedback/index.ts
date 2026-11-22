// Supabase Edge Function: POST /functions/v1/horme-feedback with a bug report or a request from Horme's settings.
// Public (JWT verification off): it only ever adds a row to horme_feedback, and holds back floods.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

// The support page posts here from the browser too.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const text = (value: unknown, max: number) => (typeof value === "string" ? value.trim().slice(0, max) : "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  let input: Record<string, unknown>;
  try { input = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const kind = ["bug", "request", "other"].includes(String(input.kind)) ? String(input.kind) : "other";
  const body = text(input.body, 4000);
  const sender = text(input.sender, 64);
  if (!body || !sender) return json({ error: "empty" }, 400);

  // At most five an hour from one install, and two hundred a day in all.
  const hour = new Date(Date.now() - 3600_000).toISOString();
  const day = new Date(Date.now() - 86_400_000).toISOString();
  const [{ count: mine }, { count: all }] = await Promise.all([
    supabase.from("horme_feedback").select("id", { count: "exact", head: true }).eq("sender", sender).gte("created_at", hour),
    supabase.from("horme_feedback").select("id", { count: "exact", head: true }).gte("created_at", day),
  ]);
  if ((mine ?? 0) >= 5 || (all ?? 0) >= 200) return json({ error: "too many" }, 429);

  const { error } = await supabase.from("horme_feedback").insert({
    kind, body, sender,
    contact: text(input.contact, 200) || null,
    app_version: text(input.app, 40) || null,
    os_version: text(input.os, 40) || null,
    device: text(input.device, 60) || null,
  });
  if (error) return json({ error: "not saved" }, 500);
  return json({ ok: true });
});
