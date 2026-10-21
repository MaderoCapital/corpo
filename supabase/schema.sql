-- =====================================================================
-- Madero Capital · Portal de marcas y web pública
-- Base de datos en Supabase (Postgres) con permisos por fila (RLS)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------

-- Equipo de Madero Capital: ve y edita todo
create table if not exists public.equipo (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nombre  text,
  creado  timestamptz not null default now()
);

-- Marcas (clientes que buscan locales)
create table if not exists public.marcas (
  id          uuid primary key default gen_random_uuid(),
  crm_id      text unique,                       -- id de la marca en el CRM interno
  nombre      text not null,
  rubro       text,
  aprobada    boolean not null default false,    -- el equipo aprueba cada marca registrada
  rechazada   boolean not null default false,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now(),
  actualizado_por text not null default 'crm'    -- 'marca' | 'equipo' | 'crm'
);

-- Personas de cada marca que entran al portal (una marca puede tener varias)
create table if not exists public.miembros (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  marca_id uuid not null references public.marcas(id) on delete cascade,
  nombre   text,
  cargo    text,
  telefono text,
  email    text,
  creado   timestamptz not null default now()
);

-- Búsquedas de cada marca (mismos campos que el CRM)
create table if not exists public.busquedas (
  id           uuid primary key default gen_random_uuid(),
  crm_id       text unique,
  marca_id     uuid not null references public.marcas(id) on delete cascade,
  titulo       text,
  operacion    text not null default 'Alquiler' check (operacion in ('Alquiler','Compra')),
  estado       text not null default 'Activa'   check (estado in ('Activa','Pausada','Cerrada')),
  m2min        numeric,
  m2max        numeric,
  frente_min   numeric,
  alq_min_ars  numeric,
  alq_max_ars  numeric,
  alq_min_usd  numeric,
  alq_max_usd  numeric,
  zonas        text,
  requisitos   text,
  borrado      boolean not null default false,
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now(),
  actualizado_por text not null default 'crm'
);
create index if not exists busquedas_marca_idx on public.busquedas(marca_id);

-- Ubicaciones buscadas dentro de cada búsqueda (puntos, tramos o zonas)
create table if not exists public.puntos (
  id           uuid primary key default gen_random_uuid(),
  crm_id       text unique,
  busqueda_id  uuid not null references public.busquedas(id) on delete cascade,
  marca_id     uuid not null references public.marcas(id) on delete cascade,
  nombre       text not null,
  forma        text not null default 'Punto' check (forma in ('Punto','Tramo','Zona')),
  estado       text not null default 'Pendiente' check (estado in ('Pendiente','Ofrecida','Cubierta','Descartada')),
  barrio       text,
  lat          double precision,
  lng          double precision,
  tramo        jsonb,                              -- [[lat,lng],[lat,lng]]
  notas        text,
  m2min        numeric,
  m2max        numeric,
  frente_min   numeric,
  borrado      boolean not null default false,
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now(),
  actualizado_por text not null default 'crm'
);
create index if not exists puntos_busqueda_idx on public.puntos(busqueda_id);
create index if not exists puntos_marca_idx on public.puntos(marca_id);

-- Locales que postulan los propietarios desde la web pública
create table if not exists public.locales (
  id          uuid primary key default gen_random_uuid(),
  creado      timestamptz not null default now(),
  nombre      text not null check (char_length(nombre) <= 200),
  telefono    text check (char_length(telefono) <= 60),
  email       text check (char_length(email) <= 200),
  direccion   text not null check (char_length(direccion) <= 300),
  barrio      text check (char_length(barrio) <= 200),
  operacion   text check (char_length(operacion) <= 40),
  superficie  numeric,
  frente      numeric,
  comentarios text check (char_length(comentarios) <= 4000),
  estado      text not null default 'Nuevo' check (estado in ('Nuevo','Contactado','En cartera','Descartado')),
  notas_equipo text,
  crm_id      text
);

-- Estado de la sincronización con el CRM
create table if not exists public.sync_estado (
  clave text primary key,
  valor text
);

-- ---------------------------------------------------------------------
-- Funciones auxiliares (security definer: leen sin pasar por RLS)
-- ---------------------------------------------------------------------

create or replace function public.es_equipo()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.equipo where user_id = auth.uid());
$$;

create or replace function public.mi_marca()
returns uuid language sql stable security definer set search_path = public as $$
  select m.marca_id
  from public.miembros m join public.marcas ma on ma.id = m.marca_id
  where m.user_id = auth.uid() and ma.aprobada and not ma.rechazada
  limit 1;
$$;

-- Quién hizo el cambio: el equipo, la marca, o la sincronización (sin usuario)
create or replace function public.marcar_cambio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.actualizado := now();
  if auth.uid() is null then
    new.actualizado_por := coalesce(nullif(current_setting('madero.origen', true), ''), 'crm');
  elsif public.es_equipo() then
    new.actualizado_por := 'equipo';
  else
    new.actualizado_por := 'marca';
  end if;
  return new;
end $$;

drop trigger if exists t_marcas_cambio on public.marcas;
create trigger t_marcas_cambio before insert or update on public.marcas
  for each row execute function public.marcar_cambio();
drop trigger if exists t_busquedas_cambio on public.busquedas;
create trigger t_busquedas_cambio before insert or update on public.busquedas
  for each row execute function public.marcar_cambio();
drop trigger if exists t_puntos_cambio on public.puntos;
create trigger t_puntos_cambio before insert or update on public.puntos
  for each row execute function public.marcar_cambio();

-- Una marca no puede cambiar la marca de un punto ni moverlo a una búsqueda de otra marca
create or replace function public.validar_punto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.busquedas b where b.id = new.busqueda_id and b.marca_id = new.marca_id) then
    raise exception 'La ubicación no corresponde a esa búsqueda';
  end if;
  return new;
end $$;
drop trigger if exists t_puntos_validar on public.puntos;
create trigger t_puntos_validar before insert or update on public.puntos
  for each row execute function public.validar_punto();

-- Al registrarse una marca: crea la marca (pendiente de aprobación) y su miembro
create or replace function public.nuevo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_marca uuid;
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if coalesce(meta->>'marca', '') = '' then
    return new;  -- usuarios del equipo u otros: sin marca
  end if;
  insert into public.marcas (nombre, rubro, aprobada)
    values (left(meta->>'marca', 200), left(meta->>'rubro', 200), false)
    returning id into v_marca;
  insert into public.miembros (user_id, marca_id, nombre, cargo, telefono, email)
    values (new.id, v_marca, left(meta->>'nombre', 200), left(meta->>'cargo', 200),
            left(meta->>'telefono', 60), new.email);
  return new;
end $$;

drop trigger if exists t_nuevo_usuario on auth.users;
create trigger t_nuevo_usuario after insert on auth.users
  for each row execute function public.nuevo_usuario();

-- El equipo aprueba una marca: como nueva, o uniéndola a una marca que ya existe (p. ej. precargada del CRM)
create or replace function public.aprobar_marca(p_marca uuid, p_unir_a uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.es_equipo() then raise exception 'Sin permiso'; end if;
  if p_unir_a is not null and p_unir_a <> p_marca then
    update public.miembros set marca_id = p_unir_a where marca_id = p_marca;
    update public.busquedas set marca_id = p_unir_a where marca_id = p_marca;
    update public.puntos set marca_id = p_unir_a where marca_id = p_marca;
    delete from public.marcas where id = p_marca;
    update public.marcas set aprobada = true, rechazada = false where id = p_unir_a;
  else
    update public.marcas set aprobada = true, rechazada = false where id = p_marca;
  end if;
end $$;

-- Mapa público: solo ubicación, barrio y superficie de búsquedas activas (sin marcas)
create or replace function public.puntos_publicos()
returns table (a double precision, o double precision, b text, mn numeric, mx numeric, t jsonb)
language sql stable security definer set search_path = public as $$
  select round(p.lat::numeric, 5)::double precision, round(p.lng::numeric, 5)::double precision,
         coalesce(p.barrio, ''), coalesce(p.m2min, b.m2min), coalesce(p.m2max, b.m2max),
         case when p.forma = 'Tramo' then p.tramo else null end
  from public.puntos p
  join public.busquedas b on b.id = p.busqueda_id
  join public.marcas ma on ma.id = p.marca_id
  where not p.borrado and not b.borrado and b.estado = 'Activa'
    and p.estado in ('Pendiente','Ofrecida')
    and ma.aprobada and not ma.rechazada
    and p.lat is not null and p.lng is not null;
$$;

-- ---------------------------------------------------------------------
-- Permisos por fila (RLS)
-- ---------------------------------------------------------------------

alter table public.equipo      enable row level security;
alter table public.marcas      enable row level security;
alter table public.miembros    enable row level security;
alter table public.busquedas   enable row level security;
alter table public.puntos      enable row level security;
alter table public.locales     enable row level security;
alter table public.sync_estado enable row level security;

-- equipo: cada uno se ve a sí mismo (para saber si es del equipo)
drop policy if exists equipo_ver on public.equipo;
create policy equipo_ver on public.equipo for select to authenticated
  using (user_id = auth.uid());

-- marcas: la marca ve la suya (aunque esté pendiente); el equipo ve y edita todas
drop policy if exists marcas_ver on public.marcas;
create policy marcas_ver on public.marcas for select to authenticated
  using (public.es_equipo() or id in (select marca_id from public.miembros where user_id = auth.uid()));
drop policy if exists marcas_equipo on public.marcas;
create policy marcas_equipo on public.marcas for all to authenticated
  using (public.es_equipo()) with check (public.es_equipo());

-- miembros: cada persona ve su ficha y la de su marca; el equipo, todas
drop policy if exists miembros_ver on public.miembros;
create policy miembros_ver on public.miembros for select to authenticated
  using (public.es_equipo() or user_id = auth.uid() or marca_id = public.mi_marca());
drop policy if exists miembros_equipo on public.miembros;
create policy miembros_equipo on public.miembros for all to authenticated
  using (public.es_equipo()) with check (public.es_equipo());

-- búsquedas: solo las de la propia marca aprobada; el equipo, todas
drop policy if exists busquedas_marca on public.busquedas;
create policy busquedas_marca on public.busquedas for all to authenticated
  using (public.es_equipo() or marca_id = public.mi_marca())
  with check (public.es_equipo() or marca_id = public.mi_marca());

-- puntos: igual que búsquedas
drop policy if exists puntos_marca on public.puntos;
create policy puntos_marca on public.puntos for all to authenticated
  using (public.es_equipo() or marca_id = public.mi_marca())
  with check (public.es_equipo() or marca_id = public.mi_marca());

-- locales: cualquiera puede postular; solo el equipo los ve y edita
drop policy if exists locales_postular on public.locales;
create policy locales_postular on public.locales for insert to anon, authenticated
  with check (estado = 'Nuevo' and notas_equipo is null and crm_id is null);
drop policy if exists locales_equipo on public.locales;
create policy locales_equipo on public.locales for all to authenticated
  using (public.es_equipo()) with check (public.es_equipo());

-- sync_estado: sin acceso desde la web (solo la sincronización, con permisos de servidor)

-- ---------------------------------------------------------------------
-- Permisos de las funciones
-- ---------------------------------------------------------------------
revoke all on function public.puntos_publicos() from public;
grant execute on function public.puntos_publicos() to anon, authenticated;
revoke all on function public.aprobar_marca(uuid, uuid) from public, anon;
grant execute on function public.aprobar_marca(uuid, uuid) to authenticated;
revoke all on function public.nuevo_usuario() from public, anon, authenticated;
