// Madero Capital · Bot de WhatsApp (11 5725-5183)
// Webhook de la API de WhatsApp (Meta). Atiende SOLO a quien escribe desde la web
// ("Hola, vengo de la web de Madero Capital"), junta los datos básicos y le pasa la charla a Lucía.
//
// Conexión: a través de Kapso (coexistencia con la app de WhatsApp Business) o directo con Meta.
// Secretos (Supabase → Edge Functions → Secrets):
//   KAPSO_API_KEY  clave de API del proyecto de Kapso (si se usa Kapso)
//   WA_PHONE_ID    id del número (Phone number ID)
//   WA_TOKEN / WA_APP_SECRET  solo si se conecta directo con Meta, sin Kapso
// En la tabla public.wa_config (solo la lee esta función):
//   verify   texto que se pone en "Verify token" al configurar el webhook
//   prueba   clave para simular charlas sin mandar mensajes reales (header x-prueba)
//   hook     clave que va en la URL del webhook (?k=...) cuando los mensajes llegan reenviados por Kapso
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const env = (k: string) => Deno.env.get(k) ?? "";
let CFG: Record<string, string> | null = null;
async function cfg(k: string): Promise<string> {
  if (!CFG) {
    const { data } = await db.from("wa_config").select("clave,valor");
    CFG = Object.fromEntries((data ?? []).map((r: any) => [r.clave, r.valor]));
  }
  return CFG[k] ?? "";
}
const PORTAL = "https://maderocapital.github.io/corpo/portal.html#registro";
const FRASE_WEB = "vengo de la web de madero capital";
const REINICIO_DIAS = 30; // si alguien vuelve a entrar desde la web después de esto, el bot lo atiende de nuevo

// ---------------------------------------------------------------- utilidades
const norm = (s: string) =>
  (s || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/\s+/g, " ").trim();
const esNo = (t: string) => /^(no|nop|nada|ninguno|ninguna|no hay|no se|no sé|-|n\/a)\.?$/.test(norm(t));
const nums = (t: string) =>
  (norm(t).replace(/(m|mt|mts|metros?)\s*(2|²|cuadrados?)(?![a-z0-9])/g, " ").match(/\d+(?:[.,]\d+)?/g) || []).map((x) => Number(x.replace(/\.(?=\d{3}\b)/g, "").replace(",", ".")));
const pideHumano = (t: string) => {
  const n = norm(t);
  return /(hablar|comunicar|atienda|atender|pasame|pasar).{0,25}(persona|alguien|humano|asesor|operador|vendedor)/.test(n) ||
    /^(persona|humano|asesor|operador)$/.test(n);
};
const mailOk = (t: string) => /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(t.trim());

type Out = { tipo: "texto"; texto: string } | { tipo: "botones"; texto: string; botones: [string, string][] } |
  { tipo: "lista"; texto: string; boton: string; filas: [string, string, string?][] };
const T = (texto: string): Out => ({ tipo: "texto", texto });
const B = (texto: string, botones: [string, string][]): Out => ({ tipo: "botones", texto, botones });
const L = (texto: string, boton: string, filas: [string, string, string?][]): Out => ({ tipo: "lista", texto, boton, filas });

async function enviar(to: string, m: Out, prueba: Out[] | null) {
  if (prueba) { prueba.push(m); return; }
  let body: Record<string, unknown>;
  if (m.tipo === "texto") body = { type: "text", text: { body: m.texto, preview_url: true } };
  else if (m.tipo === "botones") {
    body = { type: "interactive", interactive: { type: "button", body: { text: m.texto },
      action: { buttons: m.botones.map(([id, title]) => ({ type: "reply", reply: { id, title } })) } } };
  } else {
    body = { type: "interactive", interactive: { type: "list", body: { text: m.texto },
      action: { button: m.boton, sections: [{ title: "Opciones", rows: m.filas.map(([id, title, description]) =>
        ({ id, title, ...(description ? { description } : {}) })) }] } } };
  }
  const kapso = env("KAPSO_API_KEY");
  const r = await fetch(kapso ? `https://api.kapso.ai/meta/whatsapp/v24.0/${env("WA_PHONE_ID")}/messages`
    : `https://graph.facebook.com/v21.0/${env("WA_PHONE_ID")}/messages`, {
    method: "POST",
    headers: { ...(kapso ? { "X-API-Key": kapso } : { Authorization: `Bearer ${env("WA_TOKEN")}` }), "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", to, ...body }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) console.error("WhatsApp API", r.status, JSON.stringify(j));
  await db.from("wa_mensajes").insert({ msg_id: j?.messages?.[0]?.id ?? null, wa_id: to, dir: "sale",
    texto: "texto" in m ? m.texto : "" });
}

async function barrioDe(dir: string): Promise<string> {
  // 1) OpenStreetMap
  try {
    const u = "https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&countrycodes=ar&limit=1&viewbox=-59.3,-34.2,-57.8,-35.1&q=" +
      encodeURIComponent(dir.replace(/\s+y\s+/i, " & ") + ", Argentina");
    const r = await fetch(u, { headers: { "Accept-Language": "es", "User-Agent": "MaderoCapital-bot/1.0 (contact@maderocapital.com.ar)" } });
    if (r.ok) {
      const a = (await r.json())?.[0]?.address;
      if (a) {
        const st = a.state || "";
        if (/ciudad aut[oó]noma|^caba$|capital federal/i.test(st) || /ciudad aut[oó]noma/i.test(a.city || ""))
          return a.suburb || a.neighbourhood || a.quarter || a.city_district || "CABA";
        const loc = a.city || a.town || a.village || a.suburb || a.hamlet || a.municipality || (a.county || "").replace(/^(partido|departamento) (de )?/i, "");
        const b = [loc, st.replace(/^provincia de /i, "")].filter((v: string, i: number, x: string[]) => v && x.indexOf(v) === i).join(", ");
        if (b) return b;
      }
    } else console.error("nominatim", r.status);
  } catch (e) { console.error("nominatim", String(e)); }
  // 2) USIG (Ciudad y conurbano): normaliza la dirección y, en CABA, da el barrio
  try {
    const n = await fetch("https://servicios.usig.buenosaires.gob.ar/normalizar/?geocodificar=true&direccion=" + encodeURIComponent(dir));
    const x = (await n.json())?.direccionesNormalizadas?.[0];
    if (x) {
      if (x.cod_partido === "caba") {
        const q = await fetch(`https://ws.usig.buenosaires.gob.ar/datos_utiles?calle=${encodeURIComponent(x.nombre_calle)}&altura=${encodeURIComponent(x.altura ?? "")}`);
        const b = (await q.json().catch(() => ({})))?.barrio;
        return b ? b.toLowerCase().replace(/(^|\s)\S/g, (m: string) => m.toUpperCase()) : "CABA";
      }
      return [x.nombre_localidad, x.nombre_partido].filter((v: string, i: number, a: string[]) => v && a.indexOf(v) === i).join(", ");
    }
  } catch (e) { console.error("usig", String(e)); }
  return "";
}

// ---------------------------------------------------------------- guion
const INICIO = B(
  "¡Hola! 👋 Gracias por escribir a Madero Capital. ¿En qué te podemos ayudar?\n\n• Quiero postular un inmueble para una marca\n• Estoy buscando un local",
  [["c_postular", "Postular inmueble"], ["c_busqueda", "Busco un local"]],
);
const P_TIPO = L("¿Cuál es tu relación con el inmueble?", "Elegir", [
  ["t_prop", "Soy propietario"], ["t_desa", "Desarrolladora"], ["t_inmo", "Inmobiliaria"],
  ["t_ref", "Conozco un local", "Sé de un local disponible"],
]);
const P_OPER = B("¿Es para alquilar, vender o las dos cosas?", [["o_alq", "Alquilar"], ["o_ven", "Vender"], ["o_amb", "Las dos"]]);
const B_OPER = B("¿Es para alquilar o comprar?", [["b_alq", "Alquilar"], ["b_com", "Comprar"]]);
const CONFIRMA = (res: string) => B(`Te resumo lo que me contaste:\n\n${res}\n\n¿Está todo bien?`, [["ok_si", "Sí, está bien"], ["ok_no", "Corregir algo"]]);
const CIERRE = "¡Perfecto, gracias! Ya tenemos todo. Lucía te va a escribir por acá en un rato.";

type Chat = { wa_id: string; nombre_wa: string | null; estado: string; camino: string | null; paso: string | null;
  datos: Record<string, any>; inicio: string; ultimo: string; terminado: string | null; local_id: string | null };

function resumen(c: Chat): string {
  const d = c.datos, l: string[] = [];
  const nom = [d.nombre, d.apellido].filter(Boolean).join(" ");
  if (nom) l.push(`👤 ${nom}`);
  if (d.email) l.push(`✉️ ${d.email}`);
  if (c.camino === "postular") {
    if (d.tipo) l.push(`Relación: ${d.tipo}${d.inmobiliaria ? ` (${d.inmobiliaria})` : ""}`);
    if (d.tipo === "Desarrolladora") {
      if (d.direccion) l.push(`Proyecto: ${d.direccion}${d.barrio ? `, ${d.barrio}` : ""}`);
      if (d.cant_locales) l.push(`Locales: ${d.cant_locales}`);
    } else if (d.tipo === "Referido") {
      if (d.local_texto) l.push(`El local: ${d.local_texto}`);
      l.push(d.prop_texto ? `Propietario: ${d.prop_texto}` : "Contacto con el propietario: hacés de nexo vos");
    } else {
      if (d.direccion) l.push(`📍 ${d.direccion}${d.barrio ? `, ${d.barrio}` : ""}`);
      if (d.operacion) l.push(`Operación: ${d.operacion}`);
      if (d.superficie != null) l.push(`Superficie: ${d.superficie} m²`);
      if (d.frente != null) l.push(`Frente: ${d.frente} m`);
    }
  } else if (c.camino === "busqueda") {
    if (d.marca) l.push(`Marca: ${d.marca}`);
    if (d.cargo) l.push(`Cargo: ${d.cargo}`);
    if (d.rubro) l.push(`Rubro: ${d.rubro}`);
    if (d.operacion) l.push(`Operación: ${d.operacion}`);
    if (d.zonas) l.push(`Zonas: ${d.zonas}`);
    if (d.m2min != null || d.sup_texto) l.push(`Superficie: ${d.m2min != null ? (d.m2max != null ? `${d.m2min} a ${d.m2max} m²` : `desde ${d.m2min} m²`) : d.sup_texto}`);
    if (d.requisitos) l.push(`Requisitos: ${d.requisitos}`);
  }
  if (d.correccion) l.push(`A corregir: ${d.correccion}`);
  return l.join("\n");
}

// Devuelve los mensajes a mandar y actualiza c (paso / datos / estado)
async function avanzar(c: Chat, txt: string, id: string): Promise<Out[]> {
  const d = c.datos, t = txt.trim(), n = norm(t);
  const ir = (p: string) => { c.paso = p; };
  const PREG: Record<string, () => Out> = {
    nombre: () => T("¿Cuál es tu nombre y apellido?"),
    email: () => T("¿Cuál es tu mail de contacto?"),
    tipo: () => P_TIPO,
    inmobiliaria: () => T("¿Cómo se llama la inmobiliaria?"),
    direccion: () => T(d.tipo === "Desarrolladora" ? "¿Cuál es la dirección del proyecto? (calle y altura)" : "¿Cuál es la dirección del local? (calle y altura)"),
    barrio: () => T("¿En qué barrio o localidad está?"),
    operacion: () => P_OPER,
    superficie: () => T("¿Cuántos m² tiene?"),
    frente: () => T("¿Cuántos metros de frente?"),
    cant_locales: () => T("¿Cuántos locales tiene el proyecto?"),
    local_texto: () => T("Si sabés los datos del local, contanos la dirección y los m². Si no, escribí \"no\" y seguimos."),
    prop_contacto: () => B("¿Tenés el contacto del propietario o preferís hacer de nexo vos?", [["pc_si", "Te paso el contacto"], ["pc_no", "Hago de nexo"]]),
    prop_texto: () => T("Pasame el nombre y el teléfono del propietario."),
    marca: () => T("¿De qué marca o empresa sos?"),
    cargo: () => T("¿Cuál es tu cargo?"),
    rubro: () => T("¿Qué rubro? (gastronomía, retail, gimnasio…)"),
    b_operacion: () => B_OPER,
    zonas: () => T("¿En qué zonas estás buscando?"),
    sup: () => T("¿Qué superficie necesitás? Podés poner un rango, por ejemplo: 80 a 150 m²."),
    requisitos: () => T("¿Hay algún requisito importante? (esquina, salida de humos, estacionamiento…). Si no, escribí \"no\"."),
    confirmar: () => CONFIRMA(resumen(c)),
    correccion: () => T("Contame qué hay que corregir y lo anoto."),
  };
  const siguiente = (p: string): Out[] => { ir(p); return [PREG[p]()]; };
  const sigPostular = (): Out[] => {
    if (d.tipo === "Inmobiliaria" && !d.inmobiliaria) return siguiente("inmobiliaria");
    if (d.tipo === "Referido") return siguiente("local_texto");
    return siguiente("direccion");
  };
  const repetir = (aviso: string): Out[] => [T(aviso), PREG[c.paso!]()];

  switch (c.paso) {
    case "inicio": {
      if (id === "c_postular" || /postul|ofrec|tengo un|inmueble|propiet/.test(n)) { c.camino = "postular"; return siguiente("nombre"); }
      if (id === "c_busqueda" || /busc|necesit|alquilar un|marca/.test(n)) { c.camino = "busqueda"; return siguiente("nombre"); }
      return [INICIO];
    }
    case "nombre": {
      const p = t.replace(/^(soy|me llamo|mi nombre es)\s+/i, "").trim().split(/\s+/);
      if (!p[0] || t.length > 120) return repetir("Perdón, no te entendí.");
      d.nombre = p[0]; d.apellido = p.slice(1).join(" ") || null;
      return siguiente("email");
    }
    case "email": {
      const m = t.match(/[^\s@]+@[^\s@]+\.[a-z]{2,}/i)?.[0];
      if (!m || !mailOk(m)) return repetir("Ese mail no parece completo, ¿me lo pasás de nuevo?");
      d.email = m.toLowerCase();
      return c.camino === "postular" ? siguiente("tipo") : siguiente("marca");
    }
    // ---- camino A: postular
    case "tipo": {
      const tipo = id === "t_prop" || /propiet|dueñ|duen/.test(n) ? "Propietario"
        : id === "t_desa" || /desarroll|constru/.test(n) ? "Desarrolladora"
        : id === "t_inmo" || /inmobil/.test(n) ? "Inmobiliaria"
        : id === "t_ref" || /conozco|se de|referid|conocid/.test(n) ? "Referido" : null;
      if (!tipo) return repetir("Elegí una de las opciones, por favor.");
      d.tipo = tipo;
      return sigPostular();
    }
    case "inmobiliaria": d.inmobiliaria = t.slice(0, 200); return siguiente("direccion");
    case "direccion": {
      d.direccion = t.slice(0, 300);
      const b = await barrioDe(t);
      if (b) {
        d.barrio_sug = b; ir("barrio_ok");
        return [B(`Según la dirección, está en ${b}. ¿Es correcto?`, [["bo_si", "Sí"], ["bo_no", "No, es otro"]])];
      }
      return siguiente("barrio");
    }
    case "barrio_ok": {
      if (id === "bo_si" || /^(si|sí|s|correcto|exacto|ok|dale)\b/.test(n)) { d.barrio = d.barrio_sug; }
      else if (id === "bo_no" || /^no\b/.test(n)) { delete d.barrio_sug; return siguiente("barrio"); }
      else d.barrio = t.slice(0, 200); // escribió directamente el barrio
      delete d.barrio_sug;
      return d.tipo === "Desarrolladora" ? siguiente("cant_locales") : siguiente("operacion");
    }
    case "barrio": d.barrio = t.slice(0, 200); return d.tipo === "Desarrolladora" ? siguiente("cant_locales") : siguiente("operacion");
    case "operacion": {
      const o = id === "o_alq" ? "Alquiler" : id === "o_ven" ? "Venta" : id === "o_amb" ? "Alquiler o venta"
        : /(las dos|ambas|ambos|los dos)/.test(n) || (/alquil/.test(n) && /vend|venta/.test(n)) ? "Alquiler o venta"
        : /alquil/.test(n) ? "Alquiler" : /vend|venta/.test(n) ? "Venta" : null;
      if (!o) return repetir("Elegí una de las opciones, por favor.");
      d.operacion = o; return siguiente("superficie");
    }
    case "superficie": {
      const x = nums(t)[0];
      if (x == null || !(x > 0)) return repetir("Necesito un número, por ejemplo: 120.");
      d.superficie = x; return siguiente("frente");
    }
    case "frente": {
      const x = nums(t)[0];
      if (x == null) { if (esNo(t)) { d.frente = null; return siguiente("confirmar"); } return repetir("Necesito un número, por ejemplo: 8.5. Si no lo sabés, escribí \"no\"."); }
      d.frente = x; return siguiente("confirmar");
    }
    case "cant_locales": {
      const x = nums(t)[0];
      if (x == null || !(x >= 1)) return repetir("Necesito un número, por ejemplo: 6.");
      d.cant_locales = Math.round(x); return [T("Con esto alcanza: después te llamamos para ver el detalle de cada local."), ...siguiente("confirmar")];
    }
    case "local_texto": d.local_texto = esNo(t) ? null : t.slice(0, 500); return siguiente("prop_contacto");
    case "prop_contacto": {
      if (id === "pc_si" || /(te paso|tengo|si\b|sí\b)/.test(n)) return siguiente("prop_texto");
      if (id === "pc_no" || /(nexo|yo|no\b)/.test(n)) { d.prop_texto = null; return siguiente("confirmar"); }
      return repetir("Elegí una de las opciones, por favor.");
    }
    case "prop_texto": d.prop_texto = t.slice(0, 300); return siguiente("confirmar");
    // ---- camino B: búsqueda
    case "marca": d.marca = t.slice(0, 200); return siguiente("cargo");
    case "cargo": d.cargo = t.slice(0, 200); return siguiente("rubro");
    case "rubro": d.rubro = t.slice(0, 200); return siguiente("b_operacion");
    case "b_operacion": {
      const o = id === "b_alq" ? "Alquiler" : id === "b_com" ? "Compra" : /alquil/.test(n) ? "Alquiler" : /compr/.test(n) ? "Compra" : null;
      if (!o) return repetir("Elegí una de las opciones, por favor.");
      d.operacion = o; return siguiente("zonas");
    }
    case "zonas": d.zonas = t.slice(0, 300); return siguiente("sup");
    case "sup": {
      const x = nums(t).filter((v) => v > 0);
      if (!x.length) { d.sup_texto = t.slice(0, 200); }
      else { d.m2min = Math.min(...x.slice(0, 2)); d.m2max = x.length > 1 ? Math.max(...x.slice(0, 2)) : null; } // un solo número → solo mínima
      return siguiente("requisitos");
    }
    case "requisitos": d.requisitos = esNo(t) ? null : t.slice(0, 1000); return siguiente("confirmar");
    // ---- cierre
    case "confirmar": {
      if (id === "ok_si" || /^(si|sí|s|ok|dale|perfecto|esta bien|todo bien|correcto)\b/.test(n)) return await terminar(c);
      if (id === "ok_no" || /(corregir|no\b|mal|cambiar)/.test(n)) return siguiente("correccion");
      return repetir("¿Está todo bien?");
    }
    case "correccion": d.correccion = t.slice(0, 1000); return await terminar(c);
  }
  return [];
}

async function terminar(c: Chat, motivo = ""): Promise<Out[]> {
  const d = c.datos;
  c.estado = "terminado"; c.paso = "fin"; c.terminado = new Date().toISOString();
  const tel = "+" + c.wa_id;
  // Postulaciones → misma tabla que el formulario de la web (y de ahí al CRM)
  if (c.camino === "postular" && d.tipo && !c.local_id) {
    const com = ["Vía WhatsApp (bot)", d.local_texto && `El local: ${d.local_texto}`, d.prop_texto && `Propietario: ${d.prop_texto}`,
      d.correccion && `A corregir: ${d.correccion}`].filter(Boolean).join(" · ");
    const { data, error } = await db.from("locales").insert({
      nombre: d.nombre || c.nombre_wa || "Sin nombre", apellido: d.apellido, telefono: tel, email: d.email,
      tipo: d.tipo, inmobiliaria: d.inmobiliaria ?? null,
      direccion: d.direccion || (d.tipo === "Referido" ? "(a confirmar)" : "(sin dirección)"), barrio: d.barrio ?? null,
      operacion: d.operacion ?? null, superficie: d.superficie ?? null, frente: d.frente ?? null,
      cant_locales: d.cant_locales ?? null, comentarios: com.slice(0, 4000),
    }).select("id").single();
    if (error) console.error("locales", error.message); else c.local_id = data.id;
  }
  const quien = [d.nombre, d.apellido].filter(Boolean).join(" ") || c.nombre_wa || "Sin nombre";
  const que = c.camino === "postular" ? "quiere postular un inmueble" : c.camino === "busqueda" ? "está buscando un local" : "escribió desde la web";
  await db.from("avisos").insert({ tipo: "whatsapp", texto:
    `${quien} (${tel}) ${que}${motivo ? ` y ${motivo}` : ""}.\n${resumen(c).split("\n").map((x) => "   " + x).join("\n")}\n   Responder: https://wa.me/${c.wa_id}` });
  const out: Out[] = [];
  if (c.camino === "busqueda") out.push(T(`Si tienen varias búsquedas, en nuestro portal pueden cargarlas todas o subir directamente su Excel: ${PORTAL}`));
  out.push(T(CIERRE));
  return out;
}

// ---------------------------------------------------------------- un mensaje entrante
async function procesar(from: string, nombreWa: string | null, msgId: string, txt: string, id: string, prueba: Out[] | null) {
  // evitar duplicados (Meta puede reenviar el mismo webhook)
  const ins = await db.from("wa_mensajes").insert({ msg_id: msgId, wa_id: from, dir: "entra", texto: txt || id });
  if (ins.error) return;

  const { data: prev } = await db.from("wa_chats").select("*").eq("wa_id", from).maybeSingle();
  const desdeWeb = norm(txt).includes(FRASE_WEB);
  let c = prev as Chat | null;
  const viejo = c && (Date.now() - new Date(c.ultimo).getTime()) / 864e5 > REINICIO_DIAS;

  if (!c || (desdeWeb && (c.estado === "bot" || viejo))) { // primera vez, o vuelve a entrar desde la web
    if (!desdeWeb) return; // no vino de la web: el bot no se mete
    c = { wa_id: from, nombre_wa: nombreWa, estado: "bot", camino: null, paso: "inicio", datos: {},
      inicio: new Date().toISOString(), ultimo: new Date().toISOString(), terminado: null, local_id: null };
    await db.from("wa_chats").upsert({ ...c, respondido: null, recordado: null });
    await enviar(from, INICIO, prueba);
    return;
  }
  if (c.estado !== "bot") { // ya está hablando con Lucía
    await db.from("wa_chats").update({ ultimo: new Date().toISOString() }).eq("wa_id", from);
    return;
  }

  let out: Out[];
  if (pideHumano(txt)) {
    await terminar(c, "pidió hablar con una persona");
    out = [T("¡Claro! Te paso con Lucía, que te escribe por acá en un rato.")];
  } else {
    out = await avanzar(c, txt, id);
  }
  await db.from("wa_chats").update({ estado: c.estado, camino: c.camino, paso: c.paso, datos: c.datos, ultimo: new Date().toISOString(),
    terminado: c.terminado, local_id: c.local_id, nombre_wa: c.nombre_wa || nombreWa }).eq("wa_id", from);
  for (const m of out) await enviar(from, m, prueba);
}

// Lucía respondió desde la app (eco de WhatsApp Business): el bot se corre
async function respondioLucia(to: string, msgId: string, txt: string) {
  const ins = await db.from("wa_mensajes").insert({ msg_id: msgId, wa_id: to, dir: "lucia", texto: txt });
  if (ins.error) return;
  const { data: c } = await db.from("wa_chats").select("estado,terminado").eq("wa_id", to).maybeSingle();
  if (!c) return;
  await db.from("wa_chats").update({ respondido: new Date().toISOString(),
    ...(c.estado === "bot" ? { estado: "terminado", terminado: new Date().toISOString(), paso: "fin" } : {}) }).eq("wa_id", to);
}

// ---------------------------------------------------------------- firma de Meta
async function firmaOk(raw: string, sig: string | null): Promise<boolean> {
  const secret = env("WA_APP_SECRET");
  if (!secret || !sig?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const hex = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  const a = sig.slice(7);
  if (a.length !== hex.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ hex.charCodeAt(i);
  return r === 0;
}

function textoDe(m: any): { txt: string; id: string } {
  if (m.type === "text") return { txt: m.text?.body ?? "", id: "" };
  if (m.type === "interactive") {
    const r = m.interactive?.button_reply || m.interactive?.list_reply || {};
    return { txt: r.title ?? "", id: r.id ?? "" };
  }
  if (m.type === "button") return { txt: m.button?.text ?? "", id: m.button?.payload ?? "" };
  return { txt: `[${m.type}]`, id: "" };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (req.method === "GET") { // verificación del webhook
    const vt = await cfg("verify");
    if (url.searchParams.get("hub.mode") === "subscribe" && vt && url.searchParams.get("hub.verify_token") === vt)
      return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
    return new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("ok");

  const raw = await req.text();
  const testKey = await cfg("prueba");
  const prueba = testKey && req.headers.get("x-prueba") === testKey ? [] as Out[] : null;
  const hook = await cfg("hook");
  const porKapso = !!hook && url.searchParams.get("k") === hook;
  if (!prueba && !porKapso && !(await firmaOk(raw, req.headers.get("x-hub-signature-256")))) return new Response("bad signature", { status: 401 });

  let body: any; try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  try {
    for (const e of body.entry ?? []) for (const ch of e.changes ?? []) {
      const v = ch.value ?? {};
      if (ch.field === "messages") {
        const nombres: Record<string, string> = {};
        for (const k of v.contacts ?? []) nombres[k.wa_id] = k.profile?.name ?? null;
        for (const m of v.messages ?? []) {
          const { txt, id } = textoDe(m);
          await procesar(m.from, nombres[m.from] ?? null, m.id, txt, id, prueba);
        }
      } else if (ch.field === "smb_message_echoes") {
        for (const m of v.message_echoes ?? []) await respondioLucia(m.to, m.id, m.text?.body ?? `[${m.type}]`);
      }
    }
  } catch (err) { console.error(err); }
  return new Response(prueba ? JSON.stringify(prueba) : "ok", { headers: { "Content-Type": "application/json" } });
});
