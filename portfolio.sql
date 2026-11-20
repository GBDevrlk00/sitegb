-- Rode este arquivo UMA vez no Supabase: SQL Editor > New query > colar > Run.
-- (Depois do projetos.sql, que cria a função gb_is_admin.)
-- Cria o portfólio da página "Trabalhos": vídeos e sites que o admin adiciona/remove pelo painel.

create or replace function public.gb_is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
$$;

create table if not exists public.portfolio (
  id bigint generated always as identity primary key,
  type text not null check (type in ('video','site')),
  title text not null check (char_length(title) between 1 and 60),
  description text check (description is null or char_length(description) <= 120),
  url text not null check (url ~* '^https?://'),
  cover_path text,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

-- Se existir uma versão antiga da tabela (coluna "kind"), alinha com o painel
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='portfolio' and column_name='kind')
     and not exists (select 1 from information_schema.columns where table_schema='public' and table_name='portfolio' and column_name='type') then
    alter table public.portfolio rename column kind to type;
  end if;
end $$;
alter table public.portfolio add column if not exists sort_order int not null default 0;

alter table public.portfolio enable row level security;

-- Qualquer visitante do site pode LER; só o admin altera.
grant select on public.portfolio to anon, authenticated;
grant insert, update, delete on public.portfolio to authenticated;

drop policy if exists "portfolio_select" on public.portfolio;
create policy "portfolio_select" on public.portfolio for select to anon, authenticated using (true);
drop policy if exists "portfolio_insert_admin" on public.portfolio;
create policy "portfolio_insert_admin" on public.portfolio for insert to authenticated with check (public.gb_is_admin());
drop policy if exists "portfolio_update_admin" on public.portfolio;
create policy "portfolio_update_admin" on public.portfolio for update to authenticated
  using (public.gb_is_admin()) with check (public.gb_is_admin());
drop policy if exists "portfolio_delete_admin" on public.portfolio;
create policy "portfolio_delete_admin" on public.portfolio for delete to authenticated using (public.gb_is_admin());

-- Imagens de capa (públicas para leitura; só o admin envia/apaga)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('portfolio', 'portfolio', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif','image/avif'])
  on conflict (id) do nothing;

drop policy if exists "portfolio_admin_total" on storage.objects;
create policy "portfolio_admin_total" on storage.objects for all to authenticated
  using (bucket_id = 'portfolio' and public.gb_is_admin())
  with check (bucket_id = 'portfolio' and public.gb_is_admin());

-- Os 6 reels que já estavam no site entram como ponto de partida (só se a tabela estiver vazia)
insert into public.portfolio (type, title, description, url, sort_order)
select 'video', 'Projeto ' || lpad(n::text, 2, '0'), 'Reel no Instagram', 'https://www.instagram.com/reel/' || id || '/', 7 - n
from unnest(array['DbvaFwSTQvB','DbjsivDzzor','DbV-Ux_O6mf','DbR0FFNzjUy','DbB5frDPTFL','DbyB3HNhdAw']) with ordinality as t(id, n)
where not exists (select 1 from public.portfolio);
