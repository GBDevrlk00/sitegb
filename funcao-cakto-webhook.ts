// Recebe os webhooks da Cakto, confere a origem e libera/remove o plano do cliente.
// Deploy com verify_jwt = false (quem chama é a Cakto, não um usuário logado).
// Segredos necessários: CAKTO_WEBHOOK_SECRET (o "secret" do webhook criado na Cakto).
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente nas Edge Functions.
import { createClient } from "npm:@supabase/supabase-js@2";

const SECRET = Deno.env.get("CAKTO_WEBHOOK_SECRET") ?? "";
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TOLERANCE_SECONDS = 5 * 60;

// Eventos que mudam o plano. Os demais recebem 200 e são ignorados.
const EVENTS = new Set([
  "purchase_approved",
  "subscription_renewed",
  "subscription_late_recovered",
  "subscription_resumed",
  "refund",
  "chargeback",
  "subscription_canceled",
]);
// Eventos que liberam acesso: só valem com o pedido realmente pago.
const GRANTS = new Set(["purchase_approved", "subscription_renewed"]);

const enc = new TextEncoder();
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const toHex = (buf: ArrayBuffer) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Comparação em tempo constante
function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// X-Cakto-Signature = "v1=" + HMAC-SHA256(secret, `${timestamp}.${corpo cru}`)
async function validSignature(raw: Uint8Array, timestamp: string | null, signature: string | null) {
  if (!timestamp || !signature) return false;
  const ts = Number(timestamp);
  if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > TOLERANCE_SECONDS) return false;

  const prefix = enc.encode(`${timestamp}.`);
  const msg = new Uint8Array(prefix.length + raw.length);
  msg.set(prefix, 0);
  msg.set(raw, prefix.length);

  const key = await crypto.subtle.importKey(
    "raw", enc.encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const expected = `v1=${toHex(await crypto.subtle.sign("HMAC", key, msg))}`;
  // o header pode trazer mais de uma versão separada por vírgula
  return signature.split(",").some((s) => safeEqual(s.trim(), expected));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  if (!SECRET || !SB_URL || !SB_KEY) {
    console.error("cakto-webhook: variáveis de ambiente ausentes");
    return json(500, { ok: false, error: "not_configured" });
  }

  const raw = new Uint8Array(await req.arrayBuffer());
  let payload: any;
  try {
    payload = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json(400, { ok: false, error: "invalid_json" });
  }

  // Origem: assinatura no header (preferida) ou o campo "secret" do corpo — ambos provam o segredo.
  const sigOk = await validSignature(raw, req.headers.get("X-Cakto-Timestamp"), req.headers.get("X-Cakto-Signature"));
  const bodyOk = typeof payload?.secret === "string" && safeEqual(payload.secret, SECRET);
  if (!sigOk && !bodyOk) return json(401, { ok: false, error: "unauthorized" });

  const event = String(payload?.event ?? "");
  if (!EVENTS.has(event)) return json(200, { ok: true, ignored: event });

  // Webhook V2 manda "data" como lista; V1 como objeto.
  const items = Array.isArray(payload.data) ? payload.data : [payload.data];
  const sb = createClient(SB_URL, SB_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const results: string[] = [];

  for (const d of items) {
    const orderId = d?.id;
    const productId = d?.product?.id;
    if (!orderId || !productId) { results.push("invalid"); continue; }
    if (GRANTS.has(event) && d.status && d.status !== "paid") { results.push("ignored:status"); continue; }

    const { data, error } = await sb.rpc("cakto_apply_event", {
      p_event: event,
      p_order_id: String(orderId),
      p_ref_id: d.refId ? String(d.refId) : null,
      p_product_id: String(productId),
      p_email: d.customer?.email ?? null,
      p_callback: d.callback ? String(d.callback) : null,
      p_amount: typeof d.amount === "number" ? d.amount : null,
    });
    if (error) {
      // Sem 2xx a Cakto não reenvia sozinha: o evento fica como falha no histórico e pode ser reenviado por lá.
      console.error("cakto-webhook: erro no banco", event, String(orderId), error.message);
      return json(500, { ok: false, error: "db_error" });
    }
    console.log("cakto-webhook", event, String(d.refId ?? orderId), data);
    results.push(String(data));
  }

  return json(200, { ok: true, results });
});
