-- Admin apaga a conta de um cliente.  (JÁ APLICADO no Supabase; guardado aqui como documentação.)
-- Apaga o usuário; a cascata remove perfil, projetos, chamados e mensagens.
-- Os vídeos do bucket "videos" são apagados pelo painel (API do storage) ANTES desta chamada.
-- Só o admin consegue chamar; recusa apagar admins ou a própria conta; eventos de pagamento
-- (cakto_events) são mantidos para auditoria, com user_id nulo.
create or replace function public.admin_delete_client(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_role  text;
  v_email text;
  v_proj  int;
  v_tk    int;
begin
  if auth.uid() is null or not public.gb_is_admin() then
    raise exception 'Apenas o administrador pode apagar contas.' using errcode = '42501';
  end if;

  select role, email into v_role, v_email from public.profiles where id = p_id;
  if not found then
    raise exception 'Conta não encontrada.' using errcode = 'P0002';
  end if;
  if p_id = auth.uid() or v_role <> 'client' then
    raise exception 'Só é possível apagar contas de clientes.' using errcode = '42501';
  end if;

  select count(*) into v_proj from public.projects where user_id = p_id;
  select count(*) into v_tk   from public.tickets  where user_id = p_id;

  delete from auth.users where id = p_id;

  return jsonb_build_object('email', v_email, 'projects', v_proj, 'tickets', v_tk);
end $$;

revoke all on function public.admin_delete_client(uuid) from public, anon;
grant execute on function public.admin_delete_client(uuid) to authenticated;
