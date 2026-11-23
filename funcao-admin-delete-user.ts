// Exclui a conta de um cliente (login + perfil + projetos + chamados + vídeos enviados).
// Só pode ser chamada por um usuário logado com role = 'admin'.
// Deploy com verify_jwt = false: o token é conferido aqui dentro (auth.getUser) e o papel, no banco.
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente nas Edge Functions.
import { createClient } from "npm:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "videos";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });
  if (!SB_URL || !SB_KEY) {
    console.error("admin-delete-user: variáveis de ambiente ausentes");
    return json(500, { ok: false, error: "not_configured" });
  }

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json(401, { ok: false, error: "unauthorized" });

  const sb = createClient(SB_URL, SB_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  // 1) quem está chamando? precisa ser admin
  const { data: auth, error: authErr } = await sb.auth.getUser(token);
  if (authErr || !auth?.user) return json(401, { ok: false, error: "unauthorized" });
  const callerId = auth.user.id;
  const { data: caller } = await sb.from("profiles").select("role").eq("id", callerId).maybeSingle();
  if (caller?.role !== "admin") return json(403, { ok: false, error: "forbidden" });

  // 2) quem será excluído?
  let body: any;
  try { body = await req.json(); } catch { return json(400, { ok: false, error: "invalid_json" }); }
  const userId = String(body?.user_id ?? "");
  if (!UUID.test(userId)) return json(400, { ok: false, error: "invalid_user_id" });
  if (userId === callerId) return json(400, { ok: false, error: "cannot_delete_self" });

  const { data: target, error: tErr } = await sb.from("profiles").select("id,email,role,plan").eq("id", userId).maybeSingle();
  if (tErr) { console.error("admin-delete-user: erro lendo perfil", tErr.message); return json(500, { ok: false, error: "db_error" }); }
  if (!target) return json(404, { ok: false, error: "not_found" });
  if (target.role !== "client") return json(403, { ok: false, error: "not_a_client" }); // nunca apaga admin

  // 3) junta os arquivos do cliente ANTES de apagar (o perfil leva os projetos junto, em cascata)
  const own = `${userId}/`;
  const paths = new Set<string>();
  const { data: projects } = await sb.from("projects").select("video_path").eq("user_id", userId);
  for (const p of projects ?? []) if (p.video_path && String(p.video_path).startsWith(own)) paths.add(String(p.video_path));
  for (let offset = 0; ; offset += 100) {
    const { data: objs, error } = await sb.storage.from(BUCKET).list(userId, { limit: 100, offset });
    if (error || !objs?.length) break;
    for (const o of objs) if (o.id) paths.add(`${own}${o.name}`); // sem id = subpasta virtual
    if (objs.length < 100) break;
  }

  // 4) apaga o login; a cascata remove perfil, projetos, chamados e mensagens (pagamentos ficam no histórico)
  const { error: delErr } = await sb.auth.admin.deleteUser(userId);
  if (delErr) {
    console.error("admin-delete-user: falha ao apagar usuário", delErr.message);
    return json(500, { ok: false, error: "delete_failed" });
  }

  // 5) apaga os vídeos (se falhar, a conta já se foi; avisamos para limpar depois)
  let removed = 0;
  let filesError = false;
  const list = [...paths];
  for (let i = 0; i < list.length; i += 100) {
    const { data, error } = await sb.storage.from(BUCKET).remove(list.slice(i, i + 100));
    if (error) { filesError = true; console.error("admin-delete-user: erro apagando arquivos", error.message); }
    else removed += data?.length ?? 0;
  }

  console.log("admin-delete-user: conta apagada", userId, "por", callerId, "arquivos", removed, "/", list.length);
  return json(200, { ok: true, files_found: list.length, files_removed: removed, files_error: filesError, had_plan: !!target.plan });
});
