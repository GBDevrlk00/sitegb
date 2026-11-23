-- Integração Cakto — rode UMA vez no Supabase: SQL Editor > New query > colar > Run.
-- (Pode rodar de novo sem problema: tudo aqui é idempotente.)
--
-- O que faz:
--  1) cakto_products : liga cada plano (master/pro/dev) a um produto da Cakto + link do checkout
--  2) cakto_events   : registra cada webhook recebido (evita processar o mesmo evento duas vezes)
--  3) cakto_apply_event : libera/remove o plano do cliente quando a Cakto avisa (chamada só pela Edge Function)
--  4) handle_new_user : contas novas nascem SEM plano (antes o plano vinha do navegador, sem pagar)

-- 1) Planos x produtos da Cakto -------------------------------------------------
create table if not exists public.cakto_products (
  product_id   text primary key,                                   -- data.product.id do webhook
  plan         text not null unique check (plan in ('master','pro','dev','teste')),
  offer_id     text,
  checkout_url text not null,                                      -- ex.: https://pay.cakto.com.br/abc123
  created_at   timestamptz not null default now()
);
-- (garante o plano 'teste' também se a tabela já existia de uma versão anterior)
alter table public.cakto_products drop constraint if exists cakto_products_plan_check;
alter table public.cakto_products add constraint cakto_products_plan_check check (plan in ('master','pro','dev','teste'));
alter table public.profiles drop constraint if exists profiles_plan_check;
alter table public.profiles add constraint profiles_plan_check check (plan in ('master','pro','dev','teste'));
alter table public.cakto_products enable row level security;
drop policy if exists "cakto_products_read" on public.cakto_products;
create policy "cakto_products_read" on public.cakto_products for select to authenticated using (true);

-- 2) Registro de eventos --------------------------------------------------------
-- Não guarda o corpo do webhook (tem CPF, telefone e o segredo): só o necessário para auditar.
create table if not exists public.cakto_events (
  id         bigint generated always as identity primary key,
  order_id   text not null,
  event      text not null,
  ref_id     text,
  product_id text,
  email      text,
  user_id    uuid references public.profiles(id) on delete set null,
  amount     numeric,
  result     text,
  created_at timestamptz not null default now(),
  unique (order_id, event)
);
alter table public.cakto_events enable row level security;
drop policy if exists "cakto_events_admin" on public.cakto_events;
create policy "cakto_events_admin" on public.cakto_events for select to authenticated
  using (public.gb_is_admin());

-- 2b) Datas da assinatura (alimentam o card "Sua Assinatura" do painel)
alter table public.profiles add column if not exists plan_started_at timestamptz;
alter table public.profiles add column if not exists plan_renews_at  timestamptz;

-- 3) Aplica um evento da Cakto ao perfil do cliente ---------------------------------
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

-- 4) Contas novas nascem sem plano ------------------------------------------------
-- Antes: o plano vinha de raw_user_meta_data (controlado pelo navegador) => qualquer um virava Master.
-- Agora: plan = null até a Cakto confirmar o pagamento. O cliente atual não é afetado.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare adm boolean := lower(new.email) = '7zsbrabos@gmail.com';
begin
  insert into public.profiles(id, name, email, role, plan)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
          lower(new.email),
          case when adm then 'admin' else 'client' end,
          null);
  return new;
end $$;

-- 5) Produtos criados na Cakto (assinaturas mensais R$ 280 / 120 / 100 + plano Teste de R$ 5, pagamento único)
--    product_id = id do produto (vem no webhook em data.product.id); o link do checkout usa o id da oferta.
insert into public.cakto_products(product_id, plan, offer_id, checkout_url) values
  ('cf88436d-28a2-4f91-91bc-072d5074fa19', 'master', 'mnzxcd5', 'https://pay.cakto.com.br/mnzxcd5'),
  ('bda92117-cb1d-4385-8c9a-54987f0f0d4b', 'dev',    '9mjpe3k', 'https://pay.cakto.com.br/9mjpe3k'),
  ('c6286a08-899f-4e60-b061-ae596065b7ee', 'pro',    'aq5s7i2', 'https://pay.cakto.com.br/aq5s7i2'),
  ('955973da-18ff-4a4e-9723-f877e5997e81', 'teste',  '3dfshvy', 'https://pay.cakto.com.br/3dfshvy')
on conflict (product_id) do update
  set plan = excluded.plan, offer_id = excluded.offer_id, checkout_url = excluded.checkout_url;
