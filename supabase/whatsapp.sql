-- =====================================================================
-- Madero Capital · Bot de WhatsApp (11 5725-5183)
-- Lo usa la Edge Function "whatsapp". Solo la función (service role) lee y escribe.
-- =====================================================================

-- Una fila por persona que escribió desde la web
create table if not exists public.wa_chats (
  wa_id       text primary key,                 -- número en formato internacional sin "+" (ej. 5491100000000)
  nombre_wa   text,                             -- nombre del perfil de WhatsApp
  estado      text not null default 'bot' check (estado in ('bot','terminado','abandonado')),
  camino      text check (camino in ('postular','busqueda')),
  paso        text,
  datos       jsonb not null default '{}'::jsonb,
  inicio      timestamptz not null default now(),
  ultimo      timestamptz not null default now(),   -- último mensaje de la persona
  terminado   timestamptz,                          -- cuándo el bot le pasó la charla a Lucía
  respondido  timestamptz,                          -- cuándo Lucía respondió desde la app
  recordado   timestamptz,                          -- último recordatorio por mail
  local_id    uuid
);
alter table public.wa_chats enable row level security;

-- Registro de mensajes (también evita procesar dos veces el mismo)
create table if not exists public.wa_mensajes (
  id      bigserial primary key,
  msg_id  text unique,
  wa_id   text not null,
  dir     text not null check (dir in ('entra','sale','lucia')),
  texto   text,
  creado  timestamptz not null default now()
);
alter table public.wa_mensajes enable row level security;
create index if not exists wa_mensajes_wa on public.wa_mensajes (wa_id, creado);

-- Los locales que entran por el bot ya generan su propio aviso de WhatsApp (con link):
-- no duplicar el aviso de "local postulado".
create or replace function public.aviso_nuevo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'marcas' then
    if not new.aprobada and not new.rechazada then
      insert into avisos(tipo, texto) values ('solicitud', 'Pidió acceso al portal la marca ' || coalesce(new.nombre, '(sin nombre)') || coalesce(' (' || new.rubro || ')', '') || '.');
    end if;
  elsif tg_table_name = 'locales' then
    if coalesce(new.comentarios, '') like 'Vía WhatsApp%' then return null; end if;
    insert into avisos(tipo, texto) values ('local',
      case when new.tipo = 'Desarrolladora' then 'Una desarrolladora postuló un proyecto' || coalesce(' de ' || new.cant_locales || ' locales', '') || ': ' else 'Se postuló un local: ' end
      || coalesce(new.direccion, '(sin dirección)') || coalesce(', ' || new.barrio, '')
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
revoke all on function public.aviso_nuevo() from public, anon, authenticated;

-- Recordatorios (corre cada hora con pg_cron):
--  * charla que quedó a mitad hace más de 2 h → se cierra y avisa con lo que haya
--  * charla terminada sin respuesta de Lucía hace más de 3 h → recordatorio (como mucho uno por día)
create or replace function public.wa_recordatorios() returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  for c in select * from wa_chats where estado = 'bot' and ultimo < now() - interval '2 hours' loop
    update wa_chats set estado = 'abandonado', terminado = now() where wa_id = c.wa_id;
    insert into avisos(tipo, texto) values ('whatsapp',
      'Dejó la charla del bot a mitad: ' || coalesce(nullif(trim(coalesce(c.datos->>'nombre','') || ' ' || coalesce(c.datos->>'apellido','')), ''), c.nombre_wa, 'sin nombre')
      || ' (+' || c.wa_id || ')' || coalesce(' · ' || (c.datos->>'email'), '')
      || case c.camino when 'postular' then ' · quería postular un inmueble' when 'busqueda' then ' · está buscando un local' else '' end
      || '. Responder: https://wa.me/' || c.wa_id);
  end loop;

  for c in select * from wa_chats
           where estado in ('terminado','abandonado') and respondido is null
             and terminado < now() - interval '3 hours'
             and terminado > now() - interval '7 days'
             and (recordado is null or recordado < now() - interval '24 hours') loop
    update wa_chats set recordado = now() where wa_id = c.wa_id;
    insert into avisos(tipo, texto) values ('whatsapp_pendiente',
      'Todavía no le respondiste a ' || coalesce(nullif(trim(coalesce(c.datos->>'nombre','') || ' ' || coalesce(c.datos->>'apellido','')), ''), c.nombre_wa, 'sin nombre')
      || ' (+' || c.wa_id || '), escribió el ' || to_char(c.terminado at time zone 'America/Argentina/Buenos_Aires', 'DD/MM "a las" HH24:MI')
      || '. Responder: https://wa.me/' || c.wa_id);
  end loop;
end $$;
revoke all on function public.wa_recordatorios() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('wa-recordatorios', '5 * * * *', 'select public.wa_recordatorios()');

-- Configuración del bot (claves no secretas para Meta; solo la lee la función)
create table if not exists public.wa_config (clave text primary key, valor text not null);
alter table public.wa_config enable row level security;
-- insert into public.wa_config values ('verify', '<verify token>'), ('prueba', '<clave de prueba>');
