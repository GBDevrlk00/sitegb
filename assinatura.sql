-- Assinatura com contagem de dias — rode UMA vez no Supabase (SQL Editor > New query > colar > Run).
-- Pode rodar de novo sem problema. Rode DEPOIS do cakto.sql e ANTES de publicar o painel novo.
--
-- O que faz:
--  1) cria plan_started_at (início) e plan_renews_at (próxima renovação) em profiles
--  2) trava: cliente não consegue alterar essas datas pelo navegador (só admin e a função da Cakto)
--  3) atualiza cakto_apply_event: cada pagamento aprovado soma 1 mês à renovação e zera a cota
--  4) preenche os clientes que já pagam, a partir do histórico em cakto_events
--     (clientes com plano dado manualmente pelo admin, sem pagamento registrado, ficam sem datas
--      e não veem o card até a próxima compra aprovada)

alter table public.profiles add column if not exists plan_started_at timestamptz;
alter table public.profiles add column if not exists plan_renews_at  timestamptz;

create or replace function public.gb_guard_plan_dates() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and not public.gb_is_admin() then
    new.plan_started_at := old.plan_started_at;
    new.plan_renews_at  := old.plan_renews_at;
  end if;
  return new;
end $$;
drop trigger if exists gb_guard_plan_dates on public.profiles;
create trigger gb_guard_plan_dates before update on public.profiles
  for each row execute function public.gb_guard_plan_dates();

create or replace function public.cakto_apply_event(
  p_event      text,
  p_order_id   text,
  p_ref_id     text,
  p_product_id text,
  p_email      text,
  p_callback   text,
  p_amount     numeric
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_plan  text;
  v_cur   text;
  v_uid   uuid;
  v_res   text;
  v_email text := nullif(lower(btrim(p_email)), '');
  v_start timestamptz;
  v_renews timestamptz;
begin
  if p_event not in ('purchase_approved','subscription_renewed','subscription_late_recovered',
                     'subscription_resumed','refund','chargeback','subscription_canceled') then
    return 'ignored:evento';
  end if;

  select plan into v_plan from public.cakto_products where product_id = p_product_id;
  if v_plan is null then return 'ignored:produto_desconhecido'; end if;

  -- Um evento que ficou sem usuário (e-mail diferente, por exemplo) pode ser reenviado pela Cakto
  -- depois que o cadastro existir: apagamos o registro antigo para reprocessar.
  delete from public.cakto_events where order_id = p_order_id and event = p_event and result = 'sem_usuario';

  insert into public.cakto_events(order_id, event, ref_id, product_id, email, amount)
  values (p_order_id, p_event, p_ref_id, p_product_id, v_email, p_amount)
  on conflict (order_id, event) do nothing;
  if not found then return 'duplicate'; end if;

  -- Quem comprou: 1º pelo token do link (id do usuário), 2º pelo e-mail do checkout.
  if p_callback ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select id into v_uid from public.profiles where id = p_callback::uuid and role = 'client';
  end if;
  if v_uid is null and v_email is not null then
    select id into v_uid from public.profiles where lower(email) = v_email and role = 'client';
  end if;

  if v_uid is null then
    update public.cakto_events set result = 'sem_usuario' where order_id = p_order_id and event = p_event;
    return 'unmatched';
  end if;

  select plan into v_cur from public.profiles where id = v_uid;

  select plan_started_at, plan_renews_at into v_start, v_renews from public.profiles where id = v_uid;

  if p_event in ('purchase_approved','subscription_renewed') then
    -- compra (ou renovação) aprovada: ativa o plano, começa uma cota nova e soma 1 mês à renovação.
    -- Renovar antes do vencimento soma a partir da data de renovação (não perde dias). Trocar de plano recomeça a contagem.
    update public.profiles set
      plan = v_plan, used_videos = 0, used_sites = 0,
      plan_started_at = case when v_cur is distinct from v_plan or v_start is null then now() else v_start end,
      plan_renews_at  = case when v_cur is distinct from v_plan then now() else greatest(coalesce(v_renews, now()), now()) end + interval '1 month'
    where id = v_uid;
    v_res := 'plano_ativado';
  elsif p_event = 'subscription_late_recovered' then
    -- pagamento atrasado recuperado: libera o plano e soma 1 mês (sem zerar a cota)
    update public.profiles set
      plan = v_plan,
      plan_started_at = coalesce(v_start, now()),
      plan_renews_at  = greatest(coalesce(v_renews, now()), now()) + interval '1 month'
    where id = v_uid;
    v_res := 'plano_ativado';
  elsif p_event = 'subscription_resumed' then
    -- assinatura retomada: libera o plano e só preenche as datas se estiverem vazias
    update public.profiles set
      plan = v_plan,
      plan_started_at = coalesce(v_start, now()),
      plan_renews_at  = coalesce(v_renews, now() + interval '1 month')
    where id = v_uid;
    v_res := 'plano_ativado';
  else
    -- reembolso, chargeback ou assinatura cancelada: só remove se for o plano que esse pedido liberou
    if v_cur = v_plan then
      update public.profiles set plan = null, plan_started_at = null, plan_renews_at = null where id = v_uid;
      v_res := 'plano_removido';
    else
      v_res := 'sem_efeito';
    end if;
  end if;

  update public.cakto_events set user_id = v_uid, result = v_res where order_id = p_order_id and event = p_event;
  return v_res;
end $$;

revoke all on function public.cakto_apply_event(text,text,text,text,text,text,numeric) from public, anon, authenticated;
grant execute on function public.cakto_apply_event(text,text,text,text,text,text,numeric) to service_role;


-- Clientes que já pagam: início = 1ª compra aprovada; renovação = último pagamento + 1 mês
update public.profiles p set
  plan_started_at = coalesce(e.first_at, e.last_at),
  plan_renews_at  = e.last_at + interval '1 month'
from (
  select user_id,
         min(created_at) filter (where event = 'purchase_approved') as first_at,
         max(created_at) filter (where event in ('purchase_approved','subscription_renewed','subscription_late_recovered')) as last_at
  from public.cakto_events
  where user_id is not null and result = 'plano_ativado'
  group by user_id
) e
where p.id = e.user_id and p.plan is not null and p.plan_renews_at is null and e.last_at is not null;
