-- Ajuste de dias e de cota pelo admin — rode UMA vez no Supabase (SQL Editor > New query > colar > Run).
-- Pode rodar de novo sem problema. Rode DEPOIS do assinatura.sql.
--
-- Por que existe: o painel gravava direto na tabela profiles, mas o papel "authenticated" não tem
-- permissão de UPDATE nela (erro "permission denied for table profiles"). Em vez de abrir a tabela,
-- estas duas funções fazem a gravação por dentro do banco e SÓ funcionam para admin.
--   admin_adjust_days : botões "- Remover dias" / "+ Adicionar dias" (Clientes)
--   admin_set_usage   : botões de cota de vídeos/sites e o +1 vídeo ao entregar um projeto

create or replace function public.admin_adjust_days(
  p_user      uuid,
  p_renews    timestamptz,
  p_set_start boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.gb_is_admin() then
    raise exception 'not allowed';
  end if;
  update public.profiles set
    plan_renews_at  = p_renews,
    plan_started_at = case when p_set_start and plan_started_at is null then now() else plan_started_at end
  where id = p_user and role = 'client';
end $$;

revoke all on function public.admin_adjust_days(uuid, timestamptz, boolean) from public, anon;
grant execute on function public.admin_adjust_days(uuid, timestamptz, boolean) to authenticated;

create or replace function public.admin_set_usage(
  p_user   uuid,
  p_videos int default null,
  p_sites  int default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.gb_is_admin() then
    raise exception 'not allowed';
  end if;
  update public.profiles set
    used_videos = coalesce(p_videos, used_videos),
    used_sites  = coalesce(p_sites,  used_sites)
  where id = p_user and role = 'client';
end $$;

revoke all on function public.admin_set_usage(uuid, int, int) from public, anon;
grant execute on function public.admin_set_usage(uuid, int, int) to authenticated;
