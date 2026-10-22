create or replace function public.eliminar_marca(p_marca uuid, p_registrar boolean default true)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_users uuid[]; v_m record;
begin
  if auth.uid() is not null and not public.es_equipo() then raise exception 'Sin permiso'; end if;
  select * into v_m from public.marcas where id = p_marca;
  if not found then return; end if;
  select coalesce(array_agg(user_id), '{}') into v_users from public.miembros where marca_id = p_marca;
  if exists (select 1 from public.equipo e where e.user_id = any(v_users)) then raise exception 'No se puede eliminar la cuenta del equipo'; end if;
  delete from public.puntos where marca_id = p_marca or busqueda_id in (select id from public.busquedas where marca_id = p_marca);
  delete from public.busquedas where marca_id = p_marca;
  delete from public.miembros where marca_id = p_marca;
  delete from public.marcas where id = p_marca;
  delete from auth.users where id = any(v_users);
  if p_registrar and v_m.crm_id is not null then
    insert into public.marcas_eliminadas(crm_id, nombre) values (v_m.crm_id, v_m.nombre);
  end if;
end $$;
revoke all on function public.eliminar_marca(uuid, boolean) from public, anon;
grant execute on function public.eliminar_marca(uuid, boolean) to authenticated;
