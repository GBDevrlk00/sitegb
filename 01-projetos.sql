-- Rode este arquivo UMA vez no Supabase: SQL Editor > New query > colar > Run.
-- Cria a tabela de projetos, o armazenamento privado de vídeos e as regras de acesso.

create or replace function public.gb_is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

create table if not exists public.projects (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text not null,
  kind text not null,
  format text,
  deadline date,
  brief text,
  link text,
  status text not null default 'solicitado' check (status in ('solicitado','producao','entregue')),
  video_path text,
  video_link text,
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);

alter table public.projects enable row level security;

drop policy if exists "projects_select" on public.projects;
create policy "projects_select" on public.projects for select to authenticated
  using (user_id = auth.uid() or public.gb_is_admin());
drop policy if exists "projects_insert_cliente" on public.projects;
create policy "projects_insert_cliente" on public.projects for insert to authenticated
  with check (user_id = auth.uid() and status = 'solicitado');
drop policy if exists "projects_update_admin" on public.projects;
create policy "projects_update_admin" on public.projects for update to authenticated
  using (public.gb_is_admin()) with check (public.gb_is_admin());

-- Armazenamento privado dos vídeos (pasta = id do cliente)
insert into storage.buckets (id, name, public) values ('videos', 'videos', false)
  on conflict (id) do nothing;

drop policy if exists "videos_admin_total" on storage.objects;
create policy "videos_admin_total" on storage.objects for all to authenticated
  using (bucket_id = 'videos' and public.gb_is_admin())
  with check (bucket_id = 'videos' and public.gb_is_admin());
drop policy if exists "videos_cliente_le_os_seus" on storage.objects;
create policy "videos_cliente_le_os_seus" on storage.objects for select to authenticated
  using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Garante que contas novas comecem com uso zerado
alter table public.profiles alter column used_videos set default 0;
alter table public.profiles alter column used_sites set default 0;

-- Permite que cada usuário altere SOMENTE o próprio nome (sem abrir acesso a plano, limites ou cargo)
create or replace function public.update_my_name(new_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  new_name := btrim(new_name);
  if char_length(new_name) < 2 or char_length(new_name) > 60 then raise exception 'invalid name'; end if;
  update public.profiles set name = new_name where id = auth.uid();
end; $$;
revoke all on function public.update_my_name(text) from public, anon;
grant execute on function public.update_my_name(text) to authenticated;
