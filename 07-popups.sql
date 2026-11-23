-- Pop-ups (anúncios) do Dashboard do cliente — rode UMA vez no Supabase (SQL Editor > New query > colar > Run).
-- Pode rodar de novo sem problema. Rode DEPOIS do projetos.sql (que cria a função gb_is_admin).
--
-- Quem vê o quê:
--  - cliente logado: só lê os pop-ups ATIVOS (e só o painel os exibe na Visão Geral);
--  - admin: lê, cria, edita, reordena, ativa/oculta e apaga todos;
--  - visitante do site (sem login): não lê nada.

create or replace function public.gb_is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

create table if not exists public.popups (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 80),
  body text check (body is null or char_length(body) <= 300),
  image_path text,
  link_url text check (link_url is null or link_url ~* '^https?://'),
  link_label text check (link_label is null or char_length(link_label) <= 30),
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

alter table public.popups enable row level security;

grant select on public.popups to authenticated;
grant insert, update, delete on public.popups to authenticated;

drop policy if exists "popups_select" on public.popups;
create policy "popups_select" on public.popups for select to authenticated
  using (active or public.gb_is_admin());
drop policy if exists "popups_insert_admin" on public.popups;
create policy "popups_insert_admin" on public.popups for insert to authenticated with check (public.gb_is_admin());
drop policy if exists "popups_update_admin" on public.popups;
create policy "popups_update_admin" on public.popups for update to authenticated
  using (public.gb_is_admin()) with check (public.gb_is_admin());
drop policy if exists "popups_delete_admin" on public.popups;
create policy "popups_delete_admin" on public.popups for delete to authenticated using (public.gb_is_admin());

-- Imagens dos pop-ups (leitura pública pelo link; só o admin envia/apaga)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('popups', 'popups', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif','image/avif'])
  on conflict (id) do nothing;

drop policy if exists "popups_admin_total" on storage.objects;
create policy "popups_admin_total" on storage.objects for all to authenticated
  using (bucket_id = 'popups' and public.gb_is_admin())
  with check (bucket_id = 'popups' and public.gb_is_admin());
