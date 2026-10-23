-- Sincronización portal ↔ CRM en funciones de la base.
-- La usan el CRM (al abrirlo, con el conector Supabase) y la tarea programada de cada hora.
-- Solo se pueden ejecutar desde el conector / service role (no desde la web pública).

create or replace function public.es_cuenta_equipo(p_marca uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from miembros x join equipo e on e.user_id = x.user_id where x.marca_id = p_marca)
$$;

create or replace function public.crm_pull(p_desde timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_desde timestamptz; r jsonb;
begin
  v_desde := coalesce(p_desde, (select valor::timestamptz from sync_estado where clave = 'ultima_sync'), '2000-01-01');
  with us as (
    select x.marca_id, jsonb_agg(jsonb_build_object('nombre', x.nombre, 'cargo', x.cargo, 'email', x.email, 'telefono', x.telefono) order by x.creado) usuarios
    from miembros x group by x.marca_id
  )
  select jsonb_build_object(
    'ahora', now(),
    'desde', v_desde,
    'sol', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'marca', m.nombre, 'rubro', m.rubro, 'creado', m.creado, 'usuarios', coalesce(us.usuarios, '[]'::jsonb)) order by m.creado)
                     from marcas m left join us on us.marca_id = m.id
                     where not m.aprobada and not m.rechazada and not es_cuenta_equipo(m.id)), '[]'::jsonb),
    'acc', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'crm_id', m.crm_id, 'estado', case when m.aprobada and not m.rechazada then 'Habilitada' else 'Deshabilitada' end,
                       'usuarios', coalesce(us.usuarios, '[]'::jsonb), 'busquedas', (select count(*) from busquedas b where b.marca_id = m.id and not b.borrado)))
                     from marcas m left join us on us.marca_id = m.id where m.crm_id is not null), '[]'::jsonb),
    'nuevas', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'nombre', m.nombre, 'rubro', m.rubro))
                        from marcas m where m.aprobada and not m.rechazada and m.crm_id is null and not es_cuenta_equipo(m.id)), '[]'::jsonb),
    'busq', coalesce((select jsonb_agg(to_jsonb(b) || jsonb_build_object('marca_crm', m.crm_id) order by b.actualizado)
                      from busquedas b join marcas m on m.id = b.marca_id
                      where b.actualizado > v_desde and b.actualizado_por in ('marca', 'equipo')), '[]'::jsonb),
    'pts', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('marca_crm', m.crm_id, 'busq_crm', b.crm_id) order by p.actualizado)
                     from puntos p join busquedas b on b.id = p.busqueda_id join marcas m on m.id = b.marca_id
                     where p.actualizado > v_desde and p.actualizado_por in ('marca', 'equipo')), '[]'::jsonb),
    'locales', coalesce((select jsonb_agg(to_jsonb(l) order by l.creado) from locales l), '[]'::jsonb),
    'elim', coalesce((select jsonb_agg(to_jsonb(e)) from marcas_eliminadas e where not e.procesada), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- p: ver los campos abajo; todos son opcionales.
create or replace function public.crm_push(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d jsonb; v uuid; v_dest uuid; v_m uuid; v_b uuid; out_m jsonb := '[]'::jsonb; n int;
begin
  perform set_config('madero.origen', 'sync', true);

  -- P1. decisiones sobre solicitudes de acceso
  for d in select * from jsonb_array_elements(coalesce(p->'sol_dec', '[]')) loop
    v := (d->>'id')::uuid;
    if es_cuenta_equipo(v) then continue; end if;
    if d->>'accion' = 'aprobar' then update marcas set aprobada = true, rechazada = false where id = v;
    elsif d->>'accion' = 'rechazar' then update marcas set aprobada = false, rechazada = true where id = v;
    elsif d->>'accion' = 'eliminar' then perform eliminar_marca(v, false);
    elsif d->>'accion' = 'unir' and d->>'unirA' is not null then
      select id into v_dest from marcas where crm_id = d->>'unirA';
      if v_dest is null then
        insert into marcas(nombre, rubro, aprobada, rechazada, crm_id) values (coalesce(d->>'unir_nombre', 'Marca'), d->>'unir_rubro', true, false, d->>'unirA') returning id into v_dest;
      end if;
      update busquedas set marca_id = v_dest where marca_id = v;
      update puntos set marca_id = v_dest where marca_id = v;
      update miembros set marca_id = v_dest where marca_id = v;
      update marcas set aprobada = false, rechazada = true, nombre = nombre || ' (unida)' where id = v;
      update marcas set aprobada = true, rechazada = false where id = v_dest;
    end if;
  end loop;

  -- P2. acceso de marcas habilitadas
  for d in select * from jsonb_array_elements(coalesce(p->'acc_dec', '[]')) loop
    if d->>'accion' = 'deshabilitar' then update marcas set aprobada = false, rechazada = true where crm_id = d->>'crm_id' and not es_cuenta_equipo(id);
    elsif d->>'accion' = 'habilitar' then update marcas set aprobada = true, rechazada = false where crm_id = d->>'crm_id' and not es_cuenta_equipo(id);
    elsif d->>'accion' = 'eliminar' then perform eliminar_marca(id, false) from marcas where crm_id = d->>'crm_id' and not es_cuenta_equipo(id);
    end if;
  end loop;

  -- P3. marcas borradas en el CRM (están en su papelera)
  perform eliminar_marca(id, false) from marcas where crm_id in (select jsonb_array_elements_text(coalesce(p->'del_marcas', '[]'))) and not es_cuenta_equipo(id);

  -- P4. bajas desde el portal ya pasadas a la papelera del CRM
  update marcas_eliminadas set procesada = true where id in (select (jsonb_array_elements_text(coalesce(p->'elim_hechas', '[]')))::bigint);

  -- P5. locales postulados: estado y notas del equipo
  update locales l set estado = x.estado, notas_equipo = x.notas_equipo, prop_crm = coalesce(x.prop_crm, l.prop_crm)
  from jsonb_to_recordset(coalesce(p->'loc_dec', '[]')) as x(id uuid, estado text, notas_equipo text, prop_crm text)
  where l.id = x.id and x.estado in ('Nuevo', 'Habilitado', 'Contactado', 'En cartera', 'Descartado');

  -- 1. ids del CRM para lo que llegó del portal
  update marcas m set crm_id = x.crm_id from jsonb_to_recordset(coalesce(p->'crm_ids'->'marcas', '[]')) as x(id uuid, crm_id text) where m.id = x.id and m.crm_id is null;
  update busquedas b set crm_id = x.crm_id from jsonb_to_recordset(coalesce(p->'crm_ids'->'busquedas', '[]')) as x(id uuid, crm_id text) where b.id = x.id and b.crm_id is null;
  update puntos t set crm_id = x.crm_id from jsonb_to_recordset(coalesce(p->'crm_ids'->'puntos', '[]')) as x(id uuid, crm_id text) where t.id = x.id and t.crm_id is null;

  -- Q5. estado que ve quien postuló
  update locales l set estado_ref = x.e, estado_ref_fecha = now()
  from jsonb_to_recordset(coalesce(p->'estado_ref', '[]')) as x(id uuid, e text)
  where l.id = x.id and l.estado_ref is distinct from x.e;

  -- 2. cambios hechos en el CRM
  perform set_config('madero.origen', 'crm', true);
  for d in select * from jsonb_array_elements(coalesce(p->'marcas_up', '[]')) loop
    update marcas set nombre = coalesce(d->>'nombre', nombre), rubro = d->>'rubro' where crm_id = d->>'crm_id'
      and (nombre is distinct from coalesce(d->>'nombre', nombre) or rubro is distinct from d->>'rubro');
    if not exists (select 1 from marcas where crm_id = d->>'crm_id') then
      insert into marcas(nombre, rubro, aprobada, rechazada, crm_id) values (coalesce(d->>'nombre', 'Marca'), d->>'rubro', true, false, d->>'crm_id') returning id into v_m;
      out_m := out_m || jsonb_build_object('crm_id', d->>'crm_id', 'id', v_m);
    end if;
  end loop;

  for d in select * from jsonb_array_elements(coalesce(p->'busq_up', '[]')) loop
    select id into v_m from marcas where crm_id = d->>'marca_crm';
    if v_m is null then continue; end if;
    insert into busquedas(crm_id, marca_id, titulo, operacion, estado, m2min, m2max, frente_min, alq_min_ars, alq_max_ars, alq_min_usd, alq_max_usd, zonas, requisitos, borrado)
    values (d->>'crm_id', v_m, d->>'titulo',
      case when d->>'operacion' in ('Alquiler', 'Compra') then d->>'operacion' else 'Alquiler' end,
      case when d->>'estado' in ('Activa', 'Pausada', 'Cerrada') then d->>'estado' else 'Activa' end,
      (d->>'m2min')::numeric, (d->>'m2max')::numeric, (d->>'frenteMin')::numeric, (d->>'alqMinArs')::numeric, (d->>'alqMaxArs')::numeric,
      (d->>'alqMinUsd')::numeric, (d->>'alqMaxUsd')::numeric, d->>'zonas', d->>'requisitos', false)
    on conflict (crm_id) do update set marca_id = excluded.marca_id, titulo = excluded.titulo, operacion = excluded.operacion, estado = excluded.estado,
      m2min = excluded.m2min, m2max = excluded.m2max, frente_min = excluded.frente_min, alq_min_ars = excluded.alq_min_ars, alq_max_ars = excluded.alq_max_ars,
      alq_min_usd = excluded.alq_min_usd, alq_max_usd = excluded.alq_max_usd, zonas = excluded.zonas, requisitos = excluded.requisitos, borrado = false
    where (busquedas.titulo, busquedas.operacion, busquedas.estado, busquedas.m2min, busquedas.m2max, busquedas.frente_min, busquedas.alq_min_ars, busquedas.alq_max_ars, busquedas.alq_min_usd, busquedas.alq_max_usd, busquedas.zonas, busquedas.requisitos, busquedas.borrado, busquedas.marca_id)
      is distinct from (excluded.titulo, excluded.operacion, excluded.estado, excluded.m2min, excluded.m2max, excluded.frente_min, excluded.alq_min_ars, excluded.alq_max_ars, excluded.alq_min_usd, excluded.alq_max_usd, excluded.zonas, excluded.requisitos, false, excluded.marca_id);
  end loop;

  for d in select * from jsonb_array_elements(coalesce(p->'pts_up', '[]')) loop
    select b.id, b.marca_id into v_b, v_m from busquedas b where b.crm_id = d->>'busq_crm';
    if v_b is null then continue; end if;
    insert into puntos(crm_id, busqueda_id, marca_id, nombre, forma, estado, barrio, lat, lng, tramo, poligono, notas, m2min, m2max, frente_min, borrado)
    values (d->>'crm_id', v_b, v_m, coalesce(d->>'nombre', 'Ubicación'),
      case when d->>'forma' = 'Cuadrante' and jsonb_typeof(d->'poligono') = 'array' and jsonb_array_length(d->'poligono') >= 3 then 'Cuadrante'
           when d->>'forma' in ('Punto', 'Tramo', 'Zona') then d->>'forma' else 'Punto' end,
      case when d->>'estado' in ('Pendiente', 'Ofrecida', 'Cubierta', 'Descartada') then d->>'estado' else 'Pendiente' end,
      d->>'barrio', (d->>'lat')::float8, (d->>'lng')::float8,
      case when jsonb_typeof(d->'tramo') = 'array' then d->'tramo' end,
      case when jsonb_typeof(d->'poligono') = 'array' then d->'poligono' end,
      d->>'notas', (d->>'m2min')::numeric, (d->>'m2max')::numeric, (d->>'frenteMin')::numeric, false)
    on conflict (crm_id) do update set busqueda_id = excluded.busqueda_id, marca_id = excluded.marca_id, nombre = excluded.nombre, forma = excluded.forma, estado = excluded.estado,
      barrio = excluded.barrio, lat = excluded.lat, lng = excluded.lng, tramo = excluded.tramo, poligono = excluded.poligono, notas = excluded.notas,
      m2min = excluded.m2min, m2max = excluded.m2max, frente_min = excluded.frente_min, borrado = false
    where (puntos.busqueda_id, puntos.nombre, puntos.forma, puntos.estado, puntos.barrio, puntos.lat, puntos.lng, puntos.tramo, puntos.poligono, puntos.notas, puntos.m2min, puntos.m2max, puntos.frente_min, puntos.borrado)
      is distinct from (excluded.busqueda_id, excluded.nombre, excluded.forma, excluded.estado, excluded.barrio, excluded.lat, excluded.lng, excluded.tramo, excluded.poligono, excluded.notas, excluded.m2min, excluded.m2max, excluded.frente_min, false);
  end loop;

  -- 2e. lo que ya no está en el CRM (solo si mandaron la lista completa)
  if jsonb_typeof(p->'busq_vivas') = 'array' then
    update busquedas set borrado = true where crm_id is not null and not borrado and crm_id not in (select jsonb_array_elements_text(p->'busq_vivas'));
  end if;
  if jsonb_typeof(p->'pts_vivos') = 'array' then
    update puntos set borrado = true where crm_id is not null and not borrado and crm_id not in (select jsonb_array_elements_text(p->'pts_vivos'));
  end if;

  -- 2f. direcciones de la cartera (aviso de repetidos en la web)
  if jsonb_typeof(p->'cartera') = 'array' and jsonb_array_length(p->'cartera') >= 10 then
    insert into cartera_dirs(prop_id, direccion, barrio)
    select x.prop_id, left(x.direccion, 300), x.barrio from jsonb_to_recordset(p->'cartera') as x(prop_id text, direccion text, barrio text)
    on conflict (prop_id) do update set direccion = excluded.direccion, barrio = excluded.barrio, activa = true, actualizado = now()
    where (cartera_dirs.direccion, cartera_dirs.barrio, cartera_dirs.activa) is distinct from (excluded.direccion, excluded.barrio, true);
    update cartera_dirs set activa = false where activa and prop_id not in (select x->>'prop_id' from jsonb_array_elements(p->'cartera') x);
  end if;

  if p ? 'ultima' then
    update sync_estado set valor = p->>'ultima' where clave = 'ultima_sync';
  end if;
  return jsonb_build_object('ok', true, 'marcas_creadas', out_m);
end $$;

revoke all on function public.crm_pull(timestamptz) from public, anon, authenticated;
revoke all on function public.crm_push(jsonb) from public, anon, authenticated;
revoke all on function public.es_cuenta_equipo(uuid) from public, anon, authenticated;

-- Avisos por mail (los manda la tarea programada a office@maderocapital.com.ar)
create table if not exists public.avisos (
  id bigserial primary key,
  tipo text not null,
  texto text not null,
  creado timestamptz not null default now(),
  enviado timestamptz
);
alter table public.avisos enable row level security;

create or replace function public.aviso_nuevo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'marcas' then
    if not new.aprobada and not new.rechazada then
      insert into avisos(tipo, texto) values ('solicitud', 'Pidió acceso al portal la marca ' || coalesce(new.nombre, '(sin nombre)') || coalesce(' (' || new.rubro || ')', '') || '.');
    end if;
  elsif tg_table_name = 'locales' then
    insert into avisos(tipo, texto) values ('local', 'Se postuló un local: ' || coalesce(new.direccion, '(sin dirección)') || coalesce(', ' || new.barrio, '')
      || ' · ' || coalesce(new.tipo, 'Propietario') || ': ' || trim(coalesce(new.nombre, '') || ' ' || coalesce(new.apellido, ''))
      || coalesce(' · ' || new.telefono, '') || coalesce(' · ' || new.email, '') || '.');
  elsif tg_table_name = 'busquedas' then
    if new.actualizado_por = 'marca' then
      insert into avisos(tipo, texto) select 'busqueda', m.nombre || ' cargó una búsqueda nueva' || coalesce(': ' || new.titulo, '') || coalesce(' (' || new.zonas || ')', '') || '.'
      from marcas m where m.id = new.marca_id;
    end if;
  end if;
  return null;
end $$;

create or replace trigger t_aviso_marca after insert on public.marcas for each row execute function public.aviso_nuevo();
create or replace trigger t_aviso_local after insert on public.locales for each row execute function public.aviso_nuevo();
create or replace trigger t_aviso_busqueda after insert on public.busquedas for each row execute function public.aviso_nuevo();
revoke all on function public.aviso_nuevo() from public, anon, authenticated;

-- Candado para que el sistema y la tarea de cada hora no sincronicen a la vez
insert into public.sync_estado(clave, valor) values ('lock', '') on conflict (clave) do nothing;
create or replace function public.crm_lock(p_quien text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update sync_estado set valor = now()::text || '|' || coalesce(p_quien, '')
  where clave = 'lock' and (coalesce(valor, '') = '' or split_part(valor, '|', 1)::timestamptz < now() - interval '4 minutes');
  return found;
end $$;
create or replace function public.crm_unlock() returns void
language sql security definer set search_path = public as $$
  update sync_estado set valor = '' where clave = 'lock';
$$;
revoke all on function public.crm_lock(text) from public, anon, authenticated;
revoke all on function public.crm_unlock() from public, anon, authenticated;
