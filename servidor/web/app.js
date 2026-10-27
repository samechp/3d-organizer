/* app.js - 3D Organizer (web).
   JS clásico, sin framework ni compilación. Todo lo que viene de la API se
   escribe en la página con textContent (nunca innerHTML): los nombres salen de
   la base de datos y no deben poder meter HTML. */

'use strict';

/* =========================================================================
   1. Utilidades
   ========================================================================= */

const ZONA = 'America/Bogota';
const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const TANDAS_POR_PAGINA = 25;

function porId(id) { return document.getElementById(id); }

// Crea un elemento: crear('button', {clase: 'boton', texto: 'Hola', enclick: fn}, hijos...).
// Las claves que empiezan con "en" son eventos; "clase" y "texto" son atajos.
function crear(etiqueta, opciones, ...hijos) {
  const nodo = document.createElement(etiqueta);
  for (const [clave, valor] of Object.entries(opciones || {})) {
    if (valor === null || valor === undefined || valor === false) continue;
    if (clave === 'clase') nodo.className = valor;
    else if (clave === 'texto') nodo.textContent = valor;
    else if (clave.startsWith('en')) nodo.addEventListener(clave.slice(2), valor);
    else if (clave === 'value' || clave === 'disabled') nodo[clave] = valor;
    else nodo.setAttribute(clave, valor === true ? '' : String(valor));
  }
  for (const hijo of hijos.flat()) {
    if (hijo === null || hijo === undefined || hijo === false) continue;
    nodo.append(hijo);
  }
  return nodo;
}

function vaciar(nodo) { nodo.replaceChildren(); }

// Miles con punto (2.837). Se hace a mano: toLocaleString('es-CO') cambia según el navegador.
function num(n) {
  return String(Math.trunc(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
}

function plural(n, singular, plural_) { return n === 1 ? singular : plural_; }

// Partes de una fecha vista desde Bogotá, sin importar la zona del navegador.
const formatoBogota = new Intl.DateTimeFormat('en-US', {
  timeZone: ZONA, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

function partesBogota(fecha) {
  const partes = {};
  for (const p of formatoBogota.formatToParts(fecha)) partes[p.type] = p.value;
  return partes;
}

function claveDia(p) { return `${p.year}-${p.month}-${p.day}`; }

// "Hoy · 3:02 p. m.", "Ayer · ..." o "22 oct · ..." (con año si no es el actual).
function cuandoTexto(iso) {
  const fecha = new Date(iso);
  if (Number.isNaN(fecha.getTime())) return String(iso);
  const p = partesBogota(fecha);
  const hoy = partesBogota(new Date());
  // Colombia no tiene horario de verano: ayer es siempre 24 horas antes.
  const ayer = partesBogota(new Date(Date.now() - 24 * 60 * 60 * 1000));
  const hora = fecha
    .toLocaleTimeString('es-CO', { timeZone: ZONA, hour: 'numeric', minute: '2-digit', hour12: true })
    .replace(/[  ]/g, ' ');
  let dia;
  if (claveDia(p) === claveDia(hoy)) dia = 'Hoy';
  else if (claveDia(p) === claveDia(ayer)) dia = 'Ayer';
  else {
    dia = `${Number(p.day)} ${MESES[Number(p.month) - 1]}`;
    if (p.year !== hoy.year) dia += ` ${p.year}`;
  }
  return `${dia} · ${hora}`;
}

// '2026-11-20' -> "20 nov" o "20 nov 2026".
function entregaTexto(fechaIso, conAnio) {
  const [a, m, d] = String(fechaIso).split('-').map(Number);
  if (!a || !m || !d) return String(fechaIso);
  return `${d} ${MESES[m - 1]}${conAnio ? ' ' + a : ''}`;
}

// Valor para un <input type="datetime-local"> con la hora de Bogotá.
function aValorLocal(fecha) {
  const p = partesBogota(fecha);
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}

// Lo que escribe el usuario es hora de Bogotá: se manda con su desfase.
function deValorLocalAIso(valor) {
  return (valor.length === 16 ? valor + ':00' : valor) + '-05:00';
}

function hacerTexto(minutos) {
  if (minutos < 1) return 'menos de 1 minuto';
  if (minutos < 60) return `${num(minutos)} min`;
  const h = Math.floor(minutos / 60), m = minutos % 60;
  return m ? `${num(h)} h ${m} min` : `${num(h)} h`;
}

// UUID para id_cliente: identifica la tanda aunque el envío se repita.
function idNuevo() {
  if (window.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

let temporizadorAviso = null;
// Aviso breve abajo; el contenedor es aria-live, así que también se lee en voz alta.
function anunciar(texto) {
  const caja = porId('aviso-breve');
  caja.textContent = texto;
  clearTimeout(temporizadorAviso);
  temporizadorAviso = setTimeout(() => { caja.textContent = ''; }, 4000);
}

function mostrarError(nodoId, texto) {
  const nodo = porId(nodoId);
  nodo.textContent = texto || '';
  nodo.hidden = !texto;
}

/* =========================================================================
   2. Llamadas a la API
   ========================================================================= */

class ErrorApi extends Error {
  constructor(estado, mensaje, cuerpo) {
    super(mensaje);
    this.mensaje = mensaje;
    this.estado = estado;
    this.cuerpo = cuerpo;
  }
}

const CAMPOS = {
  cantidad: 'Buenas', cuando: 'Fecha y hora', nombre: 'Nombre', cliente: 'Cliente',
  entrega: 'Entrega', nota: 'Nota', meta: 'Meta', modelos: 'Modelos', modelo_id: 'Modelo',
  correo: 'Correo', clave: 'Contraseña', foto: 'Foto', id_cliente: 'Identificador',
  opcion_id: 'Opción', opciones: 'Opciones', tipo: 'Qué', hechos: 'Ya hechos',
};

function textoValidacion(fallo) {
  const campo = [...(fallo.loc || [])].reverse().find((x) => CAMPOS[x]);
  const c = fallo.ctx || {};
  const tipo = String(fallo.type || '');
  let porque;
  if ('ge' in c && 'le' in c) porque = `debe estar entre ${num(c.ge)} y ${num(c.le)}`;
  else if ('ge' in c) porque = `debe ser ${num(c.ge)} o más`;
  else if ('le' in c) porque = `debe ser ${num(c.le)} o menos`;
  else if (tipo === 'string_too_short') porque = 'no puede estar vacío';
  else if (tipo === 'string_too_long') porque = `es demasiado largo (máximo ${num(c.max_length)})`;
  else if (tipo === 'too_short') porque = 'necesita al menos uno';
  else if (tipo === 'too_long') porque = `admite hasta ${num(c.max_length)}`;
  else if (tipo === 'missing') porque = 'falta';
  else if (tipo.startsWith('int_')) porque = 'debe ser un número entero';
  else if (tipo.includes('date')) porque = 'no es una fecha válida';
  else if (tipo === 'value_error') porque = String(fallo.msg || '').replace(/^Value error, /, '');
  else porque = 'no es válido';
  return campo ? `${CAMPOS[campo]} ${porque}` : porque.charAt(0).toUpperCase() + porque.slice(1);
}

function mensajeDeError(estado, cuerpo) {
  const detalle = cuerpo && cuerpo.detail;
  if (typeof detalle === 'string' && detalle) return detalle;
  if (estado === 422 && Array.isArray(detalle)) {
    return 'Revisa los datos: ' + detalle.map(textoValidacion).join('. ') + '.';
  }
  if (estado === 401) return 'Tu sesión venció. Entra de nuevo.';
  if (estado === 429) return 'Demasiados intentos. Prueba de nuevo en unos minutos.';
  if (estado >= 500) return 'El servidor tuvo un problema. Intenta de nuevo en un momento.';
  return 'No se pudo completar la acción.';
}

// Hace la petición y devuelve el JSON (null si no hay cuerpo). Cualquier otra
// cosa lanza ErrorApi. Un 401 fuera del login manda a la pantalla de entrar.
async function pedir(metodo, ruta, cuerpo, opciones = {}) {
  const cabeceras = {};
  // Con cookie, el servidor exige X-Sistema en todo lo que cambia datos (CSRF).
  if (metodo !== 'GET') cabeceras['X-Sistema'] = '1';
  let envio;
  if (cuerpo instanceof FormData) {
    envio = cuerpo; // el navegador pone el Content-Type con su boundary
  } else if (cuerpo !== undefined) {
    cabeceras['Content-Type'] = 'application/json';
    envio = JSON.stringify(cuerpo);
  }

  let respuesta;
  try {
    respuesta = await fetch(ruta, { method: metodo, headers: cabeceras, body: envio, credentials: 'same-origin' });
  } catch (e) {
    throw new ErrorApi(0, 'No hay conexión con el servidor. Revisa tu internet e intenta de nuevo.', null);
  }

  let datos = null;
  if (respuesta.status !== 204) {
    try { datos = await respuesta.json(); } catch (e) { datos = null; }
  }
  if (respuesta.ok) return datos;

  if (respuesta.status === 401 && !opciones.sinRedirigir) sesionVencida();
  throw new ErrorApi(respuesta.status, mensajeDeError(respuesta.status, datos), datos);
}

// Muestra el error en un contenedor, salvo el 401: ya se mostró la pantalla de entrar.
function manejarError(e, nodoId) {
  if (e instanceof ErrorApi && e.estado === 401) return;
  mostrarError(nodoId, e instanceof ErrorApi ? e.mensaje : 'Algo salió mal. Intenta de nuevo.');
  if (!(e instanceof ErrorApi)) console.error(e);
}

/* =========================================================================
   3. Estado
   ========================================================================= */

const estado = {
  pedidos: [],            // resumen de todos los pedidos (abiertos y terminados)
  verTerminados: false,
  pedidoId: null,         // pedido que se está viendo
  detalle: null,          // GET /api/pedidos/{id}
  tandas: [],             // GET /api/pedidos/{id}/tandas
  tandasVisibles: TANDAS_POR_PAGINA,
  formPedidoId: null,     // pedido para el que está preparado el formulario de tanda
  cuandoTocado: false,    // false = "ahora": no se manda fecha y manda el servidor
  intento: null,          // {id, modeloId, cantidad, cuando}: el envío en curso
  aviso: null,            // la tanda parecida que mandó el 409
  enviando: false,
  dialogo: null,          // {modo: 'nuevo'|'editar', filas: [...]}
  seccion: null,          // 'pedidos' o 'productos': la pestaña que se ve
};

/* =========================================================================
   4. Pantallas: entrar y panel
   ========================================================================= */

function mostrarEntrar(mensaje) {
  porId('pantalla-panel').hidden = true;
  porId('pantalla-productos').hidden = true;
  porId('secciones').hidden = true;
  porId('zona-sesion').hidden = true;
  porId('pantalla-entrar').hidden = false;
  if (porId('dialogo-pedido').open) porId('dialogo-pedido').close();
  if (porId('dialogo-producto').open) porId('dialogo-producto').close();
  if (porId('dialogo-usuarios').open) porId('dialogo-usuarios').close();
  porId('entrar-clave').value = '';
  mostrarError('entrar-error', mensaje);
  porId('entrar-boton').disabled = false;
  (porId('entrar-correo').value ? porId('entrar-clave') : porId('entrar-correo')).focus();
}

function mostrarPanel(correo, dueno) {
  porId('boton-usuarios').hidden = !dueno;
  porId('pantalla-entrar').hidden = true;
  porId('secciones').hidden = false;
  porId('zona-sesion').hidden = false;
  porId('correo-sesion').textContent = correo || '';
}

// Borra lo que había en pantalla: el siguiente en entrar no debe ver datos del anterior.
function reiniciarEstado() {
  estado.pedidos = [];
  estado.pedidoId = null;
  estado.detalle = null;
  estado.tandas = [];
  estado.formPedidoId = null;
  estado.intento = null;
  estado.aviso = null;
  estado.verTerminados = false;
  estado.seccion = null;
  prod.lista = [];
  prod.productoId = null;
  prod.detalle = null;
  prod.formProductoId = null;
  prod.intento = null;
  prod.aviso = null;
}

// La sesión venció (401 en cualquier petición). Si varias peticiones fallan a la
// vez, solo la primera encuentra la sesión visible y hace el cambio.
function sesionVencida() {
  if (porId('zona-sesion').hidden) return;
  reiniciarEstado();
  mostrarEntrar('Tu sesión venció. Entra de nuevo.');
}

async function entrar(evento) {
  evento.preventDefault();
  const correo = porId('entrar-correo').value.trim();
  const clave = porId('entrar-clave').value;
  if (!correo || !clave) {
    mostrarError('entrar-error', 'Escribe tu correo y tu contraseña.');
    return;
  }
  mostrarError('entrar-error', '');
  porId('entrar-boton').disabled = true;
  try {
    const r = await pedir('POST', '/api/acceso', { correo, clave }, { sinRedirigir: true });
    porId('entrar-clave').value = '';
    mostrarPanel(r && r.correo, r && r.dueno);
    await iniciarPanel();
  } catch (e) {
    // Aquí un 401 es "correo o contraseña incorrectos" y sí se muestra.
    mostrarError('entrar-error', e instanceof ErrorApi ? e.mensaje : 'Algo salió mal. Intenta de nuevo.');
  } finally {
    porId('entrar-boton').disabled = false;
  }
}

async function salir() {
  try {
    await pedir('POST', '/api/salir', undefined, { sinRedirigir: true });
  } catch (e) { /* aunque falle, se vuelve a la pantalla de entrar */ }
  reiniciarEstado();
  mostrarEntrar('');
}

/* =========================================================================
   5. Lista de pedidos
   ========================================================================= */

function idDeHash() {
  const m = /^#\/pedido\/(\d+)$/.exec(location.hash);
  return m ? Number(m[1]) : null;
}

function textoLinea(p) {
  const av = p.avance;
  const partes = [`${num(av.contadas)} de ${num(av.meta_total)}`];
  if (p.estado === 'terminado') partes.push('terminado');
  else partes.push(p.entrega ? `entrega ${entregaTexto(p.entrega)}` : 'sin fecha');
  return partes.join(' · ');
}

function elementoPedido(p) {
  const completo = p.avance.faltan <= 0;
  const vencido = p.estado === 'abierto' && p.ritmo && p.ritmo.vencido;
  const enlace = crear('a', {
    clase: 'pedido-item', href: `#/pedido/${p.id}`,
    'aria-current': p.id === estado.pedidoId ? 'page' : false,
  },
    crear('span', { clase: 'nombre', texto: p.nombre }),
    p.cliente ? crear('span', { clase: 'detalle', texto: p.cliente }) : null,
    crear('span', { clase: 'detalle' + (vencido ? ' vencido' : ''), texto: textoLinea(p) + (vencido ? ' · vencido' : '') }),
    crear('span', { clase: 'mini-barra' + (completo ? ' completo' : ''), 'aria-hidden': 'true' },
      crear('div', { style: `width:${p.avance.porcentaje}%` })),
  );
  return crear('li', null, enlace);
}

function dibujarLista() {
  const abiertos = estado.pedidos.filter((p) => p.estado === 'abierto');
  const terminados = estado.pedidos.filter((p) => p.estado === 'terminado');

  const listaAbiertos = porId('lista-abiertos');
  vaciar(listaAbiertos);
  abiertos.forEach((p) => listaAbiertos.append(elementoPedido(p)));
  porId('sin-abiertos').hidden = abiertos.length > 0;

  // Si el pedido que se ve es uno terminado, la lista de terminados se abre sola.
  const seleccionado = estado.pedidos.find((p) => p.id === estado.pedidoId);
  if (seleccionado && seleccionado.estado === 'terminado') estado.verTerminados = true;

  const boton = porId('boton-terminados');
  const lista = porId('lista-terminados');
  boton.hidden = terminados.length === 0;
  boton.textContent = estado.verTerminados
    ? `Ocultar terminados (${num(terminados.length)})`
    : `Ver terminados (${num(terminados.length)})`;
  boton.setAttribute('aria-expanded', String(estado.verTerminados));
  lista.hidden = !(estado.verTerminados && terminados.length > 0);
  vaciar(lista);
  terminados.forEach((p) => lista.append(elementoPedido(p)));
}

async function cargarPedidos() {
  estado.pedidos = await pedir('GET', '/api/pedidos');
  dibujarLista();
}

/* =========================================================================
   6. Detalle: encabezado, avance y tarjetas por modelo
   ========================================================================= */

function ritmoTexto(ritmo, faltan) {
  if (!ritmo) return null;
  if (ritmo.completo) return { texto: 'Pedido completo', clase: 'completo' };
  if (ritmo.vencido) {
    const n = ritmo.vencido_hace;
    return { texto: `Entrega vencida hace ${num(n)} ${plural(n, 'día', 'días')}`, clase: 'vencido' };
  }
  return {
    texto: `Faltan ${num(faltan)} en ${num(ritmo.dias)} ${plural(ritmo.dias, 'día', 'días')}: ${num(ritmo.por_dia)} al día`,
    clase: '',
  };
}

function dibujarEncabezado(d) {
  porId('detalle-nombre').textContent = d.nombre;
  const partes = [];
  if (d.cliente) partes.push(d.cliente);
  partes.push(`${num(d.modelos.length)} ${plural(d.modelos.length, 'modelo', 'modelos')}`);
  if (d.entrega) partes.push(`entrega ${entregaTexto(d.entrega, true)}`);
  if (d.estado === 'terminado' && d.terminado_en) partes.push(`terminado: ${cuandoTexto(d.terminado_en)}`);
  porId('detalle-sub').textContent = partes.join(' · ');

  const nota = porId('detalle-nota');
  nota.textContent = d.nota || '';
  nota.hidden = !d.nota;

  porId('boton-terminar').textContent = d.estado === 'terminado' ? 'Reabrir pedido' : 'Marcar terminado';
}

function dibujarAvance(d) {
  const av = d.avance;
  const completo = av.faltan <= 0;
  const total = porId('avance-total');
  total.textContent = `${num(av.contadas)} de ${num(av.meta_total)}`;
  total.append(crear('small', { texto: `  ${av.porcentaje} %` }));

  const r = ritmoTexto(d.ritmo, av.faltan);
  const insignia = porId('avance-ritmo');
  insignia.hidden = !r;
  if (r) {
    insignia.textContent = r.texto;
    insignia.className = 'insignia' + (r.clase ? ' ' + r.clase : '');
  }

  const barra = porId('avance-barra');
  barra.className = 'barra-avance' + (completo ? ' completo' : '');
  barra.setAttribute('aria-valuenow', String(av.porcentaje));
  barra.setAttribute('aria-valuetext', `${av.porcentaje} %`);
  barra.firstElementChild.style.width = `${av.porcentaje}%`;
}

function tarjetaModelo(m) {
  const pct = Math.min(100, (m.hechas / m.meta) * 100);
  const nota = m.completo
    ? (m.de_mas > 0 ? `Completo · ${num(m.de_mas)} de más` : 'Completo')
    : `Faltan ${num(m.faltan)}`;

  const foto = crear('div', { clase: 'modelo-foto', 'aria-hidden': m.foto_url ? false : 'true' });
  if (m.foto_url) {
    const img = crear('img', { src: m.foto_url, alt: `Foto de ${m.nombre}`, loading: 'lazy' });
    // Si la foto no carga, se vuelve al recuadro sin foto en vez de mostrar un ícono roto.
    img.addEventListener('error', () => { img.remove(); foto.textContent = 'Sin foto'; });
    foto.append(img);
  } else {
    foto.textContent = 'Sin foto';
  }

  const entrada = crear('input', {
    type: 'file', accept: 'image/jpeg,image/png', hidden: true,
    'aria-label': `Elegir foto de ${m.nombre}`,
    enchange: () => { if (entrada.files[0]) subirFoto(m, entrada.files[0]); entrada.value = ''; },
  });
  const botonFoto = crear('button', {
    type: 'button', clase: 'modelo-foto-boton', texto: m.foto_url ? 'Cambiar foto' : 'Subir foto',
    'aria-label': `${m.foto_url ? 'Cambiar' : 'Subir'} foto de ${m.nombre}`,
    enclick: () => entrada.click(),
  });

  return crear('div', { clase: 'modelo' + (m.completo ? ' completo' : '') },
    foto,
    crear('div', { clase: 'modelo-cuerpo' },
      crear('div', { clase: 'modelo-titulo' },
        crear('b', { texto: m.nombre }),
        crear('span', { texto: `${num(m.hechas)} / ${num(m.meta)}` })),
      crear('div', { clase: 'barra-mini', 'aria-hidden': 'true' }, crear('div', { style: `width:${pct}%` })),
      crear('span', { clase: 'modelo-nota', texto: nota }),
      botonFoto, entrada));
}

function dibujarTarjetas(d) {
  const cont = porId('tarjetas');
  vaciar(cont);
  d.modelos.forEach((m) => cont.append(tarjetaModelo(m)));
}

function dibujarDetalle() {
  const d = estado.detalle;
  const hay = !!d;
  porId('detalle').hidden = !hay;
  porId('caja-avance').hidden = !hay;
  porId('caja-tanda').hidden = !hay;
  porId('caja-historial').hidden = !hay;
  porId('sin-pedidos').hidden = hay || estado.pedidos.length > 0;
  if (!hay) return;
  dibujarEncabezado(d);
  dibujarAvance(d);
  dibujarTarjetas(d);
  prepararFormularioTanda(d);
  dibujarHistorial();
}

async function cargarDetalle(id) {
  const [detalle, tandas] = await Promise.all([
    pedir('GET', `/api/pedidos/${id}`),
    pedir('GET', `/api/pedidos/${id}/tandas`),
  ]);
  if (id !== estado.pedidoId) return; // el usuario ya eligió otro pedido
  estado.detalle = detalle;
  estado.tandas = tandas;
  dibujarDetalle();
}

async function seleccionar(id, opciones = {}) {
  estado.pedidoId = id;
  estado.detalle = null;
  estado.tandas = [];
  estado.tandasVisibles = TANDAS_POR_PAGINA;
  mostrarError('error-general', '');
  dibujarLista();
  try {
    await cargarDetalle(id);
    if (opciones.desplazar) {
      // En el teléfono la lista queda arriba y el detalle abajo: se baja al detalle.
      porId('principal').scrollIntoView({ block: 'start' });
      porId('detalle-nombre').focus({ preventScroll: true });
    }
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 404) {
      // El pedido ya no existe: se recarga la lista (para que ya no salga) y se
      // vuelve al primero abierto.
      estado.pedidoId = null;
      try {
        await cargarPedidos();
        await elegirPedidoInicial();
      } catch (e2) {
        manejarError(e2, 'error-general');
      }
      return;
    }
    dibujarDetalle();
    manejarError(e, 'error-general');
  }
}

async function elegirPedidoInicial() {
  const deHash = idDeHash();
  const abierto = estado.pedidos.find((p) => p.estado === 'abierto');
  const id = estado.pedidos.some((p) => p.id === deHash) ? deHash : (abierto ? abierto.id : (estado.pedidos[0] || {}).id);
  if (id) {
    history.replaceState(null, '', `#/pedido/${id}`);
    await seleccionar(id);
  } else {
    history.replaceState(null, '', location.pathname + location.search);
    estado.pedidoId = null;
    estado.detalle = null;
    dibujarLista();
    dibujarDetalle();
  }
}

// Vuelve a pedir lista y detalle (después de guardar algo).
async function refrescar() {
  const tareas = [cargarPedidos()];
  if (estado.pedidoId) tareas.push(cargarDetalle(estado.pedidoId));
  await Promise.all(tareas);
}

async function marcarTerminado() {
  const d = estado.detalle;
  if (!d) return;
  const terminando = d.estado === 'abierto';
  if (terminando && d.avance.faltan > 0 &&
      !confirm(`Todavía faltan ${num(d.avance.faltan)} piezas. ¿Marcar el pedido como terminado de todos modos?`)) {
    return;
  }
  mostrarError('error-general', '');
  try {
    await pedir('PATCH', `/api/pedidos/${d.id}`, { estado: terminando ? 'terminado' : 'abierto' });
    await refrescar();
    anunciar(terminando ? 'Pedido marcado como terminado' : 'Pedido reabierto');
  } catch (e) {
    manejarError(e, 'error-general');
  }
}

/* =========================================================================
   7. Anotar tanda
   ========================================================================= */

function ponerCuandoAhora() {
  porId('tanda-cuando').value = aValorLocal(new Date());
  estado.cuandoTocado = false;
  porId('tanda-ahora').hidden = true;
}

// Deja el formulario listo para el pedido que se ve. Si es el mismo de antes
// (por ejemplo después de guardar) no se borra lo que el usuario escribió.
function prepararFormularioTanda(d) {
  const select = porId('tanda-modelo');
  const previo = select.value;
  vaciar(select);
  d.modelos.forEach((m) => {
    select.append(crear('option', { value: String(m.id), texto: m.completo ? `${m.nombre} (completo)` : m.nombre }));
  });
  if (d.id === estado.formPedidoId) {
    if (d.modelos.some((m) => String(m.id) === previo)) select.value = previo;
  } else {
    estado.formPedidoId = d.id;
    porId('tanda-cantidad').value = '';
    estado.intento = null;
    estado.aviso = null;
    ponerCuandoAhora();
    mostrarError('tanda-error', '');
    dibujarAviso();
  }
}

function nombreDelModelo(id) {
  const m = estado.detalle && estado.detalle.modelos.find((x) => x.id === id);
  return m ? m.nombre : 'ese modelo';
}

function dibujarAviso() {
  const cont = porId('aviso-tanda');
  vaciar(cont);
  const p = estado.aviso;
  if (!p) return;
  const modelo = nombreDelModelo(estado.intento ? estado.intento.modeloId : Number(porId('tanda-modelo').value));
  const distancia = estado.intento && estado.intento.cuando
    ? `a ${hacerTexto(p.hace_minutos)} de la hora que pusiste`
    : `hace ${hacerTexto(p.hace_minutos)}`;
  cont.append(crear('div', null,
    crear('span', null,
      crear('b', { texto: '¿Es otra tanda?' }),
      ` Ya anotaste ${num(p.cantidad)} de ${modelo}: ${cuandoTexto(p.cuando)} (${distancia}).`),
    crear('div', { clase: 'botones' },
      crear('button', { type: 'button', clase: 'boton-aviso', texto: 'Sí, guardar', enclick: () => guardarTanda(true) }),
      crear('button', { type: 'button', clase: 'boton-aviso-claro', texto: 'No, ya estaba', enclick: descartarAviso }))));
}

function descartarAviso() {
  estado.aviso = null;
  estado.intento = null;
  dibujarAviso();
  anunciar('Listo, no se guardó otra tanda');
  porId('tanda-cantidad').focus();
}

// Cualquier cambio en el formulario deja sin efecto el aviso de "otra tanda".
function formularioCambio() {
  if (estado.aviso) {
    estado.aviso = null;
    dibujarAviso();
  }
  mostrarError('tanda-error', '');
}

async function guardarTanda(forzar) {
  if (estado.enviando || !estado.detalle) return;
  mostrarError('tanda-error', '');

  const modeloId = Number(porId('tanda-modelo').value);
  const texto = porId('tanda-cantidad').value.trim();
  const cantidad = Number(texto);
  if (!modeloId) { mostrarError('tanda-error', 'Elige el modelo.'); return; }
  if (!texto || !Number.isInteger(cantidad) || cantidad < 1 || cantidad > 100000) {
    mostrarError('tanda-error', 'Escribe cuántas piezas buenas salieron (un número de 1 a 100.000).');
    porId('tanda-cantidad').focus();
    return;
  }
  const valorCuando = porId('tanda-cuando').value;
  if (estado.cuandoTocado && !valorCuando) {
    mostrarError('tanda-error', 'Escribe la fecha y la hora, o toca «Ahora».');
    return;
  }
  const cuando = estado.cuandoTocado ? deValorLocalAIso(valorCuando) : null;

  // Mientras sea la misma tanda (mismos datos) se reutiliza el id: si el envío
  // anterior se perdió a medias, el servidor reconoce el reintento y no la duplica.
  const i = estado.intento;
  if (!i || i.modeloId !== modeloId || i.cantidad !== cantidad || i.cuando !== cuando) {
    estado.intento = { id: idNuevo(), modeloId, cantidad, cuando };
  }
  const cuerpo = { id_cliente: estado.intento.id, modelo_id: modeloId, cantidad, forzar: !!forzar };
  if (cuando) cuerpo.cuando = cuando;

  estado.enviando = true;
  porId('tanda-guardar').disabled = true;
  try {
    await pedir('POST', '/api/tandas', cuerpo);
    estado.aviso = null;
    estado.intento = null;
    dibujarAviso();
    ponerCuandoAhora();
    anunciar(`Tanda guardada: ${num(cantidad)} de ${nombreDelModelo(modeloId)}`);
    // La tanda ya quedó en el servidor: si lo que falla es volver a pedir la
    // lista, decir "No hay conexión" haría pensar que no se guardó y anotarla otra vez.
    try {
      await refrescar();
    } catch (e) {
      if (!(e instanceof ErrorApi && e.estado === 401)) {
        mostrarError('tanda-error', 'Guardada, pero no se pudo actualizar la lista. Recarga la página en un momento.');
      }
    }
    porId('tanda-cantidad').focus();
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 409 && e.cuerpo && e.cuerpo.parecida) {
      estado.aviso = e.cuerpo.parecida;
      dibujarAviso();
    } else {
      manejarError(e, 'tanda-error');
    }
  } finally {
    estado.enviando = false;
    porId('tanda-guardar').disabled = false;
  }
}

/* =========================================================================
   8. Historial: editar en línea y borrar
   ========================================================================= */

function filaTanda(t) {
  const etiqueta = `${num(t.cantidad)} de ${t.modelo}`;
  return crear('li', { clase: 'tanda', 'data-tanda': t.id },
    crear('span', { clase: 'cuando', texto: cuandoTexto(t.cuando) }),
    crear('span', { clase: 'modelo-nombre', texto: t.modelo }),
    crear('span', { clase: 'cantidad', texto: num(t.cantidad) }),
    crear('div', { clase: 'botones' },
      crear('button', {
        type: 'button', clase: 'boton-suave', texto: 'Editar',
        'aria-label': `Editar tanda de ${etiqueta}`, enclick: () => editarTanda(t),
      }),
      crear('button', {
        type: 'button', clase: 'boton-peligro', texto: 'Borrar',
        'aria-label': `Borrar tanda de ${etiqueta}`, enclick: () => borrarTanda(t),
      })));
}

function dibujarHistorial() {
  const lista = porId('historial');
  vaciar(lista);
  estado.tandas.slice(0, estado.tandasVisibles).forEach((t) => lista.append(filaTanda(t)));
  porId('historial-vacio').hidden = estado.tandas.length > 0;
  const mas = porId('historial-mas');
  const restantes = estado.tandas.length - estado.tandasVisibles;
  mas.hidden = restantes <= 0;
  mas.textContent = `Mostrar más (${num(restantes)} ${plural(restantes, 'tanda', 'tandas')})`;
}

function enfocarEditar(id) {
  const boton = document.querySelector(`li[data-tanda="${id}"] .boton-suave`);
  if (boton) boton.focus();
}

function editarTanda(t) {
  const fila = document.querySelector(`li[data-tanda="${t.id}"]`);
  if (!fila) return;
  const valorInicial = aValorLocal(new Date(t.cuando));
  const cant = crear('input', {
    clase: 'campo', type: 'number', inputmode: 'numeric', min: 1, max: 100000, step: 1, value: String(t.cantidad),
  });
  const cuando = crear('input', { clase: 'campo', type: 'datetime-local', value: valorInicial });
  const error = crear('div', { clase: 'mensaje-error', role: 'alert', hidden: true });

  async function guardar() {
    const n = Number(cant.value);
    if (!cant.value.trim() || !Number.isInteger(n) || n < 1 || n > 100000) {
      error.textContent = 'Las buenas deben ser un número de 1 a 100.000.';
      error.hidden = false;
      cant.focus();
      return;
    }
    if (!cuando.value) {
      error.textContent = 'Escribe la fecha y la hora.';
      error.hidden = false;
      return;
    }
    const cambios = {};
    if (n !== t.cantidad) cambios.cantidad = n;
    // Solo se manda la fecha si la cambió: así no se pierden los segundos guardados.
    if (cuando.value !== valorInicial) cambios.cuando = deValorLocalAIso(cuando.value);
    if (!Object.keys(cambios).length) { cancelar(); return; }
    guardarBoton.disabled = true;
    try {
      await pedir('PATCH', `/api/tandas/${t.id}`, cambios);
      await refrescar();
      anunciar('Tanda actualizada');
      enfocarEditar(t.id);
    } catch (e) {
      guardarBoton.disabled = false;
      if (e instanceof ErrorApi && e.estado === 401) return;
      error.textContent = e instanceof ErrorApi ? e.mensaje : 'Algo salió mal. Intenta de nuevo.';
      error.hidden = false;
    }
  }

  function cancelar() {
    const nueva = filaTanda(t);
    fila.replaceWith(nueva);
    enfocarEditar(t.id);
  }

  const guardarBoton = crear('button', { type: 'submit', clase: 'boton', texto: 'Guardar' });
  const formulario = crear('form', { clase: 'tanda-edicion', novalidate: true },
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: `Buenas (${t.modelo})` }), cant),
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: 'Fecha y hora' }), cuando),
    crear('div', { clase: 'botones' },
      guardarBoton,
      crear('button', { type: 'button', clase: 'boton-secundario', texto: 'Cancelar', enclick: cancelar })));
  formulario.addEventListener('submit', (ev) => { ev.preventDefault(); guardar(); });

  fila.className = 'tanda editando';
  vaciar(fila);
  fila.append(formulario, error);
  cant.focus();
}

async function borrarTanda(t) {
  if (!confirm(`¿Borrar la tanda de ${num(t.cantidad)} de ${t.modelo} (${cuandoTexto(t.cuando)})?`)) return;
  mostrarError('error-general', '');
  try {
    await pedir('DELETE', `/api/tandas/${t.id}`);
    anunciar('Tanda borrada');
    // Igual que al guardar: ya se borró, lo que falló es solo actualizar la lista.
    try {
      await refrescar();
    } catch (e) {
      if (!(e instanceof ErrorApi && e.estado === 401)) {
        mostrarError('error-general', 'Borrada, pero no se pudo actualizar la lista. Recarga la página en un momento.');
      }
    }
  } catch (e) {
    // Si ya no existía (404) igual se refresca para que desaparezca de la lista.
    if (e instanceof ErrorApi && e.estado === 404) { try { await refrescar(); } catch (_) { /* nada */ } }
    manejarError(e, 'error-general');
  }
}

/* =========================================================================
   9. Diálogo: nuevo pedido y editar pedido
   ========================================================================= */

const MAX_MODELOS = 50;

// Una fila del diálogo. `id` es null mientras el modelo no existe en el servidor.
function crearFilaModelo(modelo) {
  const fila = {
    id: modelo ? modelo.id : null,
    nombreOriginal: modelo ? modelo.nombre : null,
    metaOriginal: modelo ? modelo.meta : null,
    hechas: modelo ? modelo.hechas : 0,
    quitar: false,
  };
  fila.nombre = crear('input', { clase: 'campo', type: 'text', maxlength: 80, required: true, value: modelo ? modelo.nombre : '' });
  fila.meta = crear('input', {
    clase: 'campo', type: 'number', inputmode: 'numeric', min: 1, max: 1000000, step: 1, required: true,
    value: modelo ? String(modelo.meta) : '',
  });
  const tieneTandas = fila.hechas > 0;
  fila.boton = crear('button', {
    type: 'button', clase: 'boton-peligro', texto: 'Quitar',
    disabled: tieneTandas,
    title: tieneTandas ? 'Este modelo ya tiene tandas: bórralas primero' : false,
    enclick: () => quitarFila(fila),
  });
  fila.li = crear('li', { clase: 'fila-modelo' },
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: 'Modelo' }), fila.nombre),
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: 'Meta' }), fila.meta),
    fila.boton);
  actualizarEtiquetaQuitar(fila);
  fila.nombre.addEventListener('input', () => actualizarEtiquetaQuitar(fila));
  return fila;
}

function actualizarEtiquetaQuitar(fila) {
  fila.boton.setAttribute('aria-label', `Quitar modelo ${fila.nombre.value || 'sin nombre'}`);
}

function quitarFila(fila) {
  const d = estado.dialogo;
  if (d.filas.filter((f) => !f.quitar).length <= 1) {
    mostrarError('pedido-error', 'El pedido necesita al menos un modelo.');
    return;
  }
  mostrarError('pedido-error', '');
  const posicion = d.filas.filter((f) => !f.quitar).indexOf(fila);
  if (fila.id === null) {
    // Nunca llegó al servidor: simplemente se descarta.
    d.filas.splice(d.filas.indexOf(fila), 1);
    fila.li.remove();
  } else {
    fila.quitar = true;
    fila.li.hidden = true;
    // Un campo oculto con required (o fuera de min/max) frena el envío del
    // formulario sin mostrar nada. Deshabilitado, el navegador no lo valida.
    fila.nombre.disabled = true;
    fila.meta.disabled = true;
  }
  const visibles = d.filas.filter((f) => !f.quitar);
  (visibles[Math.max(0, posicion - 1)] || visibles[0]).nombre.focus();
  porId('agregar-modelo').hidden = visibles.length >= MAX_MODELOS;
}

function agregarFila(modelo) {
  const d = estado.dialogo;
  if (d.filas.filter((f) => !f.quitar).length >= MAX_MODELOS) return null;
  const fila = crearFilaModelo(modelo);
  d.filas.push(fila);
  porId('filas-modelos').append(fila.li);
  porId('agregar-modelo').hidden = d.filas.filter((f) => !f.quitar).length >= MAX_MODELOS;
  return fila;
}

function abrirDialogo(modo) {
  const dialogo = porId('dialogo-pedido');
  const d = estado.detalle;
  estado.dialogo = { modo, filas: [] };
  vaciar(porId('filas-modelos'));
  mostrarError('pedido-error', '');
  porId('pedido-guardar').disabled = false;
  porId('agregar-modelo').hidden = false;

  if (modo === 'editar' && d) {
    porId('dialogo-titulo').textContent = 'Editar pedido';
    porId('pedido-nombre').value = d.nombre;
    porId('pedido-cliente').value = d.cliente || '';
    porId('pedido-entrega').value = d.entrega || '';
    porId('pedido-nota').value = d.nota || '';
    d.modelos.forEach((m) => agregarFila(m));
  } else {
    porId('dialogo-titulo').textContent = 'Nuevo pedido';
    porId('pedido-nombre').value = '';
    porId('pedido-cliente').value = '';
    porId('pedido-entrega').value = '';
    porId('pedido-nota').value = '';
    agregarFila(null);
  }
  dialogo.showModal();
  porId('pedido-nombre').focus();
}

async function guardarPedido(evento) {
  evento.preventDefault();
  const d = estado.dialogo;
  const boton = porId('pedido-guardar');
  mostrarError('pedido-error', '');

  const vivas = d.filas.filter((f) => !f.quitar);
  if (!vivas.length) { mostrarError('pedido-error', 'El pedido necesita al menos un modelo.'); return; }

  const datos = {
    nombre: porId('pedido-nombre').value.trim(),
    cliente: porId('pedido-cliente').value.trim() || null,
    entrega: porId('pedido-entrega').value || null,
    nota: porId('pedido-nota').value.trim() || null,
  };
  const modelos = vivas.map((f) => ({ fila: f, nombre: f.nombre.value.trim(), meta: Number(f.meta.value) }));
  for (const m of modelos) {
    if (!m.nombre) { mostrarError('pedido-error', 'Todos los modelos necesitan nombre.'); m.fila.nombre.focus(); return; }
    if (!Number.isInteger(m.meta) || m.meta < 1 || m.meta > 1000000) {
      mostrarError('pedido-error', 'La meta de cada modelo va de 1 a 1.000.000.');
      m.fila.meta.focus();
      return;
    }
  }

  boton.disabled = true;
  try {
    if (d.modo === 'nuevo') {
      const nuevo = await pedir('POST', '/api/pedidos', {
        ...datos, modelos: modelos.map((m) => ({ nombre: m.nombre, meta: m.meta })),
      });
      porId('dialogo-pedido').close();
      anunciar('Pedido creado');
      try {
        await cargarPedidos();
        location.hash = `#/pedido/${nuevo.id}`;
      } catch (e) {
        manejarError(e, 'error-general');
      }
      return;
    }
    await guardarCambiosPedido(datos, modelos);
  } catch (e) {
    manejarError(e, 'pedido-error');
  } finally {
    boton.disabled = false;
  }
}

// Edita el pedido y luego sus modelos uno por uno. Cada paso hecho se anota en
// su fila (id nuevo, nombre y meta guardados, fila quitada), así que si algo falla
// a la mitad se puede volver a tocar Guardar sin repetir lo que ya quedó.
async function guardarCambiosPedido(datos, modelos) {
  const d = estado.dialogo;
  const id = estado.detalle.id;
  try {
    await pedir('PATCH', `/api/pedidos/${id}`, datos);

    for (const fila of d.filas.filter((f) => f.quitar).slice()) {
      await pedir('DELETE', `/api/modelos/${fila.id}`);
      d.filas.splice(d.filas.indexOf(fila), 1);
      fila.li.remove();
    }
    for (const m of modelos) {
      const fila = m.fila;
      if (fila.id === null) {
        const creado = await pedir('POST', `/api/pedidos/${id}/modelos`, { nombre: m.nombre, meta: m.meta });
        fila.id = creado.id;
        fila.nombreOriginal = creado.nombre;
        fila.metaOriginal = creado.meta;
      } else if (m.nombre !== fila.nombreOriginal || m.meta !== fila.metaOriginal) {
        const cambios = {};
        if (m.nombre !== fila.nombreOriginal) cambios.nombre = m.nombre;
        if (m.meta !== fila.metaOriginal) cambios.meta = m.meta;
        await pedir('PATCH', `/api/modelos/${fila.id}`, cambios);
        fila.nombreOriginal = m.nombre;
        fila.metaOriginal = m.meta;
      }
    }
  } catch (e) {
    // Lo que sí se guardó ya se ve detrás del diálogo.
    try { await refrescar(); } catch (_) { /* el error original es el que importa */ }
    throw e;
  }
  porId('dialogo-pedido').close();
  anunciar('Pedido actualizado');
  try {
    await refrescar();
  } catch (e) {
    manejarError(e, 'error-general');
  }
}

/* =========================================================================
   10. Fotos de los modelos
   ========================================================================= */

async function subirFoto(modelo, archivo) {
  mostrarError('error-general', '');
  if (archivo.size > 3 * 1024 * 1024) {
    mostrarError('error-general', `La foto de ${modelo.nombre} pesa más de 3 MB. Elige una más liviana.`);
    return;
  }
  const formulario = new FormData();
  formulario.append('foto', archivo);
  try {
    anunciar('Subiendo foto…');
    await pedir('PUT', `/api/modelos/${modelo.id}/foto`, formulario);
    await refrescar();
    anunciar(`Foto de ${modelo.nombre} guardada`);
  } catch (e) {
    manejarError(e, 'error-general');
  }
}

/* =========================================================================
   11. Productos: stock por opción (las tandas suman, las ventas restan)
   ========================================================================= */

const MAX_OPCIONES = 50;

const prod = {
  lista: [],              // GET /api/productos
  productoId: null,       // producto que se está viendo
  detalle: null,          // GET /api/productos/{id} (con los últimos 30 movimientos)
  formProductoId: null,   // producto para el que está preparado el formulario de anotar
  cuandoTocado: false,    // false = "ahora": no se manda fecha y manda el servidor
  intento: null,          // {id, opcionId, tipo, cantidad, cuando}: el envío en curso
  aviso: null,            // la tanda parecida que mandó el 409
  enviando: false,
  dialogo: null,          // {modo: 'nuevo'|'editar', filas: [...]}
};

function idProductoDeHash() {
  const m = /^#productos\/(\d+)$/.exec(location.hash);
  return m ? Number(m[1]) : null;
}

// Saldo de una opción: positivo es stock, negativo lo que falta imprimir.
function saldoTexto(saldo) {
  if (saldo > 0) return `${num(saldo)} en stock`;
  if (saldo < 0) return `Faltan ${num(-saldo)}`;
  return '0';
}

function resumenProducto(p) {
  const partes = [];
  if (p.faltan > 0) partes.push(`Faltan ${num(p.faltan)}`);
  if (p.stock > 0) partes.push(`${num(p.stock)} en stock`);
  return partes.join(' · ') || 'Sin stock';
}

function dibujarListaProductos() {
  // "Por imprimir": las opciones en negativo de todos los productos, la que más falta primero.
  const faltantes = [];
  prod.lista.forEach((p) => p.opciones.forEach((o) => { if (o.saldo < 0) faltantes.push({ p, o }); }));
  faltantes.sort((a, b) => a.o.saldo - b.o.saldo);
  const porImprimir = porId('lista-por-imprimir');
  vaciar(porImprimir);
  faltantes.forEach(({ p, o }) => porImprimir.append(crear('li', null,
    crear('a', { clase: 'fila-falta', href: `#productos/${p.id}` },
      crear('span', { texto: `${p.nombre} · ${o.nombre}` }),
      crear('b', { texto: `Faltan ${num(-o.saldo)}` })))));
  porImprimir.hidden = faltantes.length === 0;
  porId('nada-por-imprimir').hidden = faltantes.length > 0;
  porId('zona-por-imprimir').hidden = prod.lista.length === 0;

  const lista = porId('lista-productos');
  vaciar(lista);
  prod.lista.forEach((p) => lista.append(crear('li', null,
    crear('a', {
      clase: 'pedido-item', href: `#productos/${p.id}`,
      'aria-current': p.id === prod.productoId ? 'page' : false,
    },
      crear('span', { clase: 'nombre', texto: p.nombre }),
      crear('span', { clase: 'detalle', texto: resumenProducto(p) })))));
  porId('sin-productos').hidden = prod.lista.length > 0;
}

async function cargarProductos() {
  prod.lista = await pedir('GET', '/api/productos');
  dibujarListaProductos();
}

function dibujarFotoProducto(d) {
  const foto = porId('producto-foto');
  vaciar(foto);
  foto.setAttribute('aria-hidden', d.foto_url ? 'false' : 'true');
  if (d.foto_url) {
    const img = crear('img', { src: d.foto_url, alt: `Foto de ${d.nombre}`, loading: 'lazy' });
    img.addEventListener('error', () => { img.remove(); foto.textContent = 'Sin foto'; });
    foto.append(img);
  } else {
    foto.textContent = 'Sin foto';
  }
  const boton = porId('boton-foto-producto');
  boton.textContent = d.foto_url ? 'Cambiar foto' : 'Subir foto';
  boton.setAttribute('aria-label', `${d.foto_url ? 'Cambiar' : 'Subir'} foto de ${d.nombre}`);
}

function dibujarProducto() {
  const d = prod.detalle;
  const hay = !!d;
  for (const id of ['producto-detalle', 'caja-opciones', 'caja-anotar', 'caja-movimientos']) porId(id).hidden = !hay;
  if (!hay) return;
  porId('producto-titulo').textContent = d.nombre;
  porId('producto-sub').textContent = resumenProducto(d);
  dibujarFotoProducto(d);

  const cont = porId('tarjetas-opciones');
  vaciar(cont);
  d.opciones.forEach((o) => {
    const clase = o.saldo > 0 ? ' completo' : (o.saldo < 0 ? '' : ' neutro');
    cont.append(crear('div', { clase: 'opcion' },
      crear('b', { texto: o.nombre }),
      crear('span', { clase: 'insignia' + clase, texto: saldoTexto(o.saldo) })));
  });
  prepararFormularioMov(d);
  dibujarMovimientos();
}

async function cargarDetalleProducto(id) {
  const detalle = await pedir('GET', `/api/productos/${id}`);
  if (id !== prod.productoId) return; // el usuario ya eligió otro producto
  prod.detalle = detalle;
  dibujarProducto();
}

async function seleccionarProducto(id, opciones = {}) {
  prod.productoId = id;
  prod.detalle = null;
  mostrarError('error-productos', '');
  dibujarListaProductos();
  try {
    await cargarDetalleProducto(id);
    if (opciones.desplazar) {
      porId('principal-productos').scrollIntoView({ block: 'start' });
      porId('producto-titulo').focus({ preventScroll: true });
    }
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 404) {
      prod.productoId = null;
      try {
        await cargarProductos();
        await elegirProductoInicial();
      } catch (e2) {
        manejarError(e2, 'error-productos');
      }
      return;
    }
    dibujarProducto();
    manejarError(e, 'error-productos');
  }
}

async function elegirProductoInicial() {
  const deHash = idProductoDeHash();
  const id = prod.lista.some((p) => p.id === deHash) ? deHash : (prod.lista[0] || {}).id;
  if (id) {
    history.replaceState(null, '', `#productos/${id}`);
    await seleccionarProducto(id);
  } else {
    history.replaceState(null, '', '#productos');
    prod.productoId = null;
    prod.detalle = null;
    dibujarListaProductos();
    dibujarProducto();
  }
}

async function refrescarProductos() {
  const tareas = [cargarProductos()];
  if (prod.productoId) tareas.push(cargarDetalleProducto(prod.productoId));
  await Promise.all(tareas);
}

/* ---------- Anotar venta o tanda ---------- */

function ponerMovCuandoAhora() {
  porId('mov-cuando').value = aValorLocal(new Date());
  prod.cuandoTocado = false;
  porId('mov-ahora').hidden = true;
}

// Igual que el de tandas: si es el mismo producto, no se borra lo escrito.
function prepararFormularioMov(d) {
  const select = porId('mov-opcion');
  const previo = select.value;
  vaciar(select);
  d.opciones.forEach((o) => select.append(crear('option', { value: String(o.id), texto: o.nombre })));
  if (d.id === prod.formProductoId) {
    if (d.opciones.some((o) => String(o.id) === previo)) select.value = previo;
  } else {
    prod.formProductoId = d.id;
    porId('mov-cantidad').value = '';
    prod.intento = null;
    prod.aviso = null;
    ponerMovCuandoAhora();
    mostrarError('mov-error', '');
    dibujarAvisoMov();
  }
}

function nombreDeOpcion(id) {
  const o = prod.detalle && prod.detalle.opciones.find((x) => x.id === id);
  return o ? o.nombre : 'esa opción';
}

function dibujarAvisoMov() {
  const cont = porId('aviso-mov');
  vaciar(cont);
  const p = prod.aviso;
  if (!p) return;
  const opcion = nombreDeOpcion(prod.intento ? prod.intento.opcionId : Number(porId('mov-opcion').value));
  const distancia = prod.intento && prod.intento.cuando
    ? `a ${hacerTexto(p.hace_minutos)} de la hora que pusiste`
    : `hace ${hacerTexto(p.hace_minutos)}`;
  cont.append(crear('div', null,
    crear('span', null,
      crear('b', { texto: '¿Es otra tanda?' }),
      ` Ya anotaste una tanda de ${num(p.cantidad)} de ${opcion}: ${cuandoTexto(p.cuando)} (${distancia}).`),
    crear('div', { clase: 'botones' },
      crear('button', { type: 'button', clase: 'boton-aviso', texto: 'Sí, guardar', enclick: () => guardarMovimiento(true) }),
      crear('button', { type: 'button', clase: 'boton-aviso-claro', texto: 'No, ya estaba', enclick: descartarAvisoMov }))));
}

function descartarAvisoMov() {
  prod.aviso = null;
  prod.intento = null;
  dibujarAvisoMov();
  anunciar('Listo, no se guardó otra tanda');
  porId('mov-cantidad').focus();
}

function formularioMovCambio() {
  if (prod.aviso) {
    prod.aviso = null;
    dibujarAvisoMov();
  }
  mostrarError('mov-error', '');
}

async function guardarMovimiento(forzar) {
  if (prod.enviando || !prod.detalle) return;
  mostrarError('mov-error', '');

  const tipo = porId('mov-tipo').value;
  const opcionId = Number(porId('mov-opcion').value);
  const texto = porId('mov-cantidad').value.trim();
  const cantidad = Number(texto);
  if (!opcionId) { mostrarError('mov-error', 'Elige la opción.'); return; }
  if (!texto || !Number.isInteger(cantidad) || cantidad < 1 || cantidad > 100000) {
    mostrarError('mov-error', 'Escribe cuántas (un número de 1 a 100.000).');
    porId('mov-cantidad').focus();
    return;
  }
  const valorCuando = porId('mov-cuando').value;
  if (prod.cuandoTocado && !valorCuando) {
    mostrarError('mov-error', 'Escribe la fecha y la hora, o toca «Ahora».');
    return;
  }
  const cuando = prod.cuandoTocado ? deValorLocalAIso(valorCuando) : null;

  // Mismos datos, mismo id: un reintento no cuenta dos veces.
  const i = prod.intento;
  if (!i || i.opcionId !== opcionId || i.tipo !== tipo || i.cantidad !== cantidad || i.cuando !== cuando) {
    prod.intento = { id: idNuevo(), opcionId, tipo, cantidad, cuando };
  }
  const cuerpo = { id_cliente: prod.intento.id, opcion_id: opcionId, tipo, cantidad, forzar: !!forzar };
  if (cuando) cuerpo.cuando = cuando;

  prod.enviando = true;
  porId('mov-guardar').disabled = true;
  try {
    await pedir('POST', '/api/movimientos', cuerpo);
    prod.aviso = null;
    prod.intento = null;
    dibujarAvisoMov();
    ponerMovCuandoAhora();
    anunciar(`${tipo === 'venta' ? 'Venta' : 'Tanda'} guardada: ${num(cantidad)} de ${nombreDeOpcion(opcionId)}`);
    // Ya quedó guardado: si falla solo el refresco, no hay que hacer pensar lo contrario.
    try {
      await refrescarProductos();
    } catch (e) {
      if (!(e instanceof ErrorApi && e.estado === 401)) {
        mostrarError('mov-error', 'Guardado, pero no se pudo actualizar la lista. Recarga la página en un momento.');
      }
    }
    porId('mov-cantidad').focus();
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 409 && e.cuerpo && e.cuerpo.parecida) {
      prod.aviso = e.cuerpo.parecida;
      dibujarAvisoMov();
    } else {
      manejarError(e, 'mov-error');
    }
  } finally {
    prod.enviando = false;
    porId('mov-guardar').disabled = false;
  }
}

/* ---------- Movimientos: editar en línea y borrar ---------- */

function etiquetaMov(m) {
  return `${m.tipo === 'venta' ? 'venta' : 'tanda'} de ${num(m.cantidad)} de ${m.opcion}`;
}

function filaMovimiento(m) {
  const venta = m.tipo === 'venta';
  return crear('tr', { 'data-mov': m.id },
    crear('td', { clase: 'cuando', texto: cuandoTexto(m.cuando) }),
    crear('td', { texto: m.opcion }),
    crear('td', { texto: venta ? 'Venta' : 'Tanda' }),
    crear('td', { clase: 'cantidad' + (venta ? '' : ' suma'), texto: (venta ? '−' : '+') + num(m.cantidad) }),
    crear('td', { clase: 'botones' },
      crear('button', {
        type: 'button', clase: 'boton-suave', texto: 'Editar',
        'aria-label': `Editar ${etiquetaMov(m)}`, enclick: () => editarMovimiento(m),
      }),
      crear('button', {
        type: 'button', clase: 'boton-peligro', texto: 'Borrar',
        'aria-label': `Borrar ${etiquetaMov(m)}`, enclick: () => borrarMovimiento(m),
      })));
}

function dibujarMovimientos() {
  const cuerpo = porId('movimientos');
  vaciar(cuerpo);
  const movs = prod.detalle ? prod.detalle.movimientos : [];
  movs.forEach((m) => cuerpo.append(filaMovimiento(m)));
  porId('movimientos-vacio').hidden = movs.length > 0;
  porId('movimientos').closest('.tabla-desliza').hidden = movs.length === 0;
}

function enfocarEditarMov(id) {
  const boton = document.querySelector(`tr[data-mov="${id}"] .boton-suave`);
  if (boton) boton.focus();
}

function editarMovimiento(m) {
  const fila = document.querySelector(`tr[data-mov="${m.id}"]`);
  if (!fila) return;
  const valorInicial = aValorLocal(new Date(m.cuando));
  const cant = crear('input', {
    clase: 'campo', type: 'number', inputmode: 'numeric', min: 1, max: 100000, step: 1, value: String(m.cantidad),
  });
  const cuando = crear('input', { clase: 'campo', type: 'datetime-local', value: valorInicial });
  const error = crear('div', { clase: 'mensaje-error', role: 'alert', hidden: true });

  function cancelar() {
    fila.replaceWith(filaMovimiento(m));
    enfocarEditarMov(m.id);
  }

  async function guardar() {
    const n = Number(cant.value);
    if (!cant.value.trim() || !Number.isInteger(n) || n < 1 || n > 100000) {
      error.textContent = 'La cantidad debe ser un número de 1 a 100.000.';
      error.hidden = false;
      cant.focus();
      return;
    }
    if (!cuando.value) {
      error.textContent = 'Escribe la fecha y la hora.';
      error.hidden = false;
      return;
    }
    const cambios = {};
    if (n !== m.cantidad) cambios.cantidad = n;
    // Solo si la cambió: así no se pierden los segundos guardados.
    if (cuando.value !== valorInicial) cambios.cuando = deValorLocalAIso(cuando.value);
    if (!Object.keys(cambios).length) { cancelar(); return; }
    guardarBoton.disabled = true;
    try {
      await pedir('PATCH', `/api/movimientos/${m.id}`, cambios);
      await refrescarProductos();
      anunciar('Movimiento actualizado');
      enfocarEditarMov(m.id);
    } catch (e) {
      guardarBoton.disabled = false;
      if (e instanceof ErrorApi && e.estado === 401) return;
      error.textContent = e instanceof ErrorApi ? e.mensaje : 'Algo salió mal. Intenta de nuevo.';
      error.hidden = false;
    }
  }

  const guardarBoton = crear('button', { type: 'submit', clase: 'boton', texto: 'Guardar' });
  const formulario = crear('form', { clase: 'tanda-edicion', novalidate: true },
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: `Cuántas (${m.opcion})` }), cant),
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: 'Fecha y hora' }), cuando),
    crear('div', { clase: 'botones' },
      guardarBoton,
      crear('button', { type: 'button', clase: 'boton-secundario', texto: 'Cancelar', enclick: cancelar })));
  formulario.addEventListener('submit', (ev) => { ev.preventDefault(); guardar(); });

  vaciar(fila);
  fila.append(crear('td', { colspan: 5 }, formulario, error));
  cant.focus();
}

async function borrarMovimiento(m) {
  if (!confirm(`¿Borrar la ${etiquetaMov(m)} (${cuandoTexto(m.cuando)})?`)) return;
  mostrarError('error-productos', '');
  try {
    await pedir('DELETE', `/api/movimientos/${m.id}`);
    anunciar('Movimiento borrado');
    try {
      await refrescarProductos();
    } catch (e) {
      if (!(e instanceof ErrorApi && e.estado === 401)) {
        mostrarError('error-productos', 'Borrado, pero no se pudo actualizar la lista. Recarga la página en un momento.');
      }
    }
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 404) { try { await refrescarProductos(); } catch (_) { /* nada */ } }
    manejarError(e, 'error-productos');
  }
}

/* ---------- Foto del producto ---------- */

async function subirFotoProducto(archivo) {
  const d = prod.detalle;
  if (!d) return;
  mostrarError('error-productos', '');
  if (archivo.size > 3 * 1024 * 1024) {
    mostrarError('error-productos', 'La foto pesa más de 3 MB. Elige una más liviana.');
    return;
  }
  const formulario = new FormData();
  formulario.append('foto', archivo);
  try {
    anunciar('Subiendo foto…');
    await pedir('PUT', `/api/productos/${d.id}/foto`, formulario);
    await refrescarProductos();
    anunciar(`Foto de ${d.nombre} guardada`);
  } catch (e) {
    manejarError(e, 'error-productos');
  }
}

/* ---------- Diálogo: nuevo producto y editar producto ---------- */

// Una fila por opción. `id` es null mientras la opción no existe en el servidor.
function crearFilaOpcion(opcion, conMovimientos) {
  const fila = {
    id: opcion ? opcion.id : null,
    nombreOriginal: opcion ? opcion.nombre : null,
    quitar: false,
    // Para la tanda inicial de una opción agregada al editar: si Guardar se
    // repite tras un fallo, el mismo id evita contarla dos veces.
    idHechos: idNuevo(),
    hechosGuardados: false,
  };
  fila.nombre = crear('input', { clase: 'campo', type: 'text', maxlength: 80, required: true, value: opcion ? opcion.nombre : '' });
  let segunda;
  if (opcion) {
    // Lo que ya existe se corrige anotando movimientos, no aquí.
    fila.hechos = null;
    segunda = crear('span', { clase: 'fila-opcion-saldo', texto: saldoTexto(opcion.saldo) });
  } else {
    fila.hechos = crear('input', {
      clase: 'campo', type: 'number', inputmode: 'numeric', min: 0, max: 100000, step: 1, placeholder: '0',
    });
    segunda = crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: '¿Ya tienes hechos?' }), fila.hechos);
  }
  fila.boton = crear('button', {
    type: 'button', clase: 'boton-peligro', texto: 'Quitar',
    disabled: conMovimientos,
    title: conMovimientos ? 'Esta opción ya tiene movimientos: bórralos primero' : false,
    enclick: () => quitarFilaOpcion(fila),
  });
  fila.li = crear('li', { clase: 'fila-modelo' },
    crear('label', { clase: 'eti' }, crear('span', { clase: 'etiqueta', texto: 'Opción' }), fila.nombre),
    segunda, fila.boton);
  const etiquetar = () => fila.boton.setAttribute('aria-label', `Quitar opción ${fila.nombre.value || 'sin nombre'}`);
  etiquetar();
  fila.nombre.addEventListener('input', etiquetar);
  return fila;
}

function vivasOpcion() { return prod.dialogo.filas.filter((f) => !f.quitar); }

function quitarFilaOpcion(fila) {
  const d = prod.dialogo;
  if (vivasOpcion().length <= 1) {
    mostrarError('producto-error', 'El producto necesita al menos una opción.');
    return;
  }
  mostrarError('producto-error', '');
  const posicion = vivasOpcion().indexOf(fila);
  if (fila.id === null) {
    d.filas.splice(d.filas.indexOf(fila), 1);
    fila.li.remove();
  } else {
    fila.quitar = true;
    fila.li.hidden = true;
    fila.nombre.disabled = true;
  }
  const visibles = vivasOpcion();
  (visibles[Math.max(0, posicion - 1)] || visibles[0]).nombre.focus();
  porId('agregar-opcion').hidden = visibles.length >= MAX_OPCIONES;
}

function agregarFilaOpcion(opcion, conMovimientos) {
  if (vivasOpcion().length >= MAX_OPCIONES) return null;
  const fila = crearFilaOpcion(opcion, conMovimientos);
  prod.dialogo.filas.push(fila);
  porId('filas-opciones').append(fila.li);
  porId('agregar-opcion').hidden = vivasOpcion().length >= MAX_OPCIONES;
  return fila;
}

function abrirDialogoProducto(modo) {
  const d = prod.detalle;
  prod.dialogo = { modo, filas: [] };
  vaciar(porId('filas-opciones'));
  mostrarError('producto-error', '');
  porId('producto-guardar').disabled = false;
  porId('agregar-opcion').hidden = false;
  if (modo === 'editar' && d) {
    porId('dialogo-producto-titulo').textContent = 'Editar producto';
    porId('producto-nombre').value = d.nombre;
    // Con saldo o con movimientos recientes seguro tiene movimientos; si tiene
    // solo antiguos, el servidor contesta 409 y se avisa.
    d.opciones.forEach((o) => agregarFilaOpcion(o, o.saldo !== 0 || d.movimientos.some((m) => m.opcion_id === o.id)));
  } else {
    porId('dialogo-producto-titulo').textContent = 'Nuevo producto';
    porId('producto-nombre').value = '';
    agregarFilaOpcion(null, false);
  }
  porId('dialogo-producto').showModal();
  porId('producto-nombre').focus();
}

async function guardarProducto(evento) {
  evento.preventDefault();
  const d = prod.dialogo;
  const boton = porId('producto-guardar');
  mostrarError('producto-error', '');

  const nombre = porId('producto-nombre').value.trim();
  if (!nombre) { mostrarError('producto-error', 'Escribe el nombre del producto.'); porId('producto-nombre').focus(); return; }
  const vivas = vivasOpcion();
  if (!vivas.length) { mostrarError('producto-error', 'El producto necesita al menos una opción.'); return; }
  const opciones = vivas.map((f) => ({
    fila: f, nombre: f.nombre.value.trim(),
    hechos: f.hechos && f.hechos.value.trim() ? Number(f.hechos.value) : 0,
  }));
  for (const o of opciones) {
    if (!o.nombre) { mostrarError('producto-error', 'Todas las opciones necesitan nombre.'); o.fila.nombre.focus(); return; }
    if (!Number.isInteger(o.hechos) || o.hechos < 0 || o.hechos > 100000) {
      mostrarError('producto-error', 'Los ya hechos van de 0 a 100.000.');
      o.fila.hechos.focus();
      return;
    }
  }

  boton.disabled = true;
  try {
    if (d.modo === 'nuevo') {
      const nuevo = await pedir('POST', '/api/productos', {
        nombre, opciones: opciones.map((o) => ({ nombre: o.nombre, hechos: o.hechos })),
      });
      porId('dialogo-producto').close();
      anunciar('Producto creado');
      try {
        await cargarProductos();
        location.hash = `#productos/${nuevo.id}`;
      } catch (e) {
        manejarError(e, 'error-productos');
      }
      return;
    }
    await guardarCambiosProducto(nombre, opciones);
  } catch (e) {
    manejarError(e, 'producto-error');
  } finally {
    boton.disabled = false;
  }
}

// Como en pedidos: cada paso hecho queda anotado en su fila, así un Guardar
// repetido tras un fallo no rehace lo que ya quedó.
async function guardarCambiosProducto(nombre, opciones) {
  const d = prod.dialogo;
  const id = prod.detalle.id;
  try {
    if (nombre !== prod.detalle.nombre) await pedir('PATCH', `/api/productos/${id}`, { nombre });

    for (const fila of d.filas.filter((f) => f.quitar).slice()) {
      try {
        await pedir('DELETE', `/api/opciones/${fila.id}`);
      } catch (e) {
        // No se pudo quitar (p. ej. tiene movimientos antiguos): vuelve a verse.
        fila.quitar = false;
        fila.li.hidden = false;
        fila.nombre.disabled = false;
        throw e;
      }
      d.filas.splice(d.filas.indexOf(fila), 1);
      fila.li.remove();
    }
    for (const o of opciones) {
      const fila = o.fila;
      if (fila.id === null) {
        const creada = await pedir('POST', `/api/productos/${id}/opciones`, { nombre: o.nombre });
        fila.id = creada.id;
        fila.nombreOriginal = creada.nombre;
      } else if (o.nombre !== fila.nombreOriginal) {
        await pedir('PATCH', `/api/opciones/${fila.id}`, { nombre: o.nombre });
        fila.nombreOriginal = o.nombre;
      }
      if (o.hechos > 0 && !fila.hechosGuardados) {
        // forzar: lo que ya había no es una tanda repetida.
        await pedir('POST', '/api/movimientos', {
          id_cliente: fila.idHechos, opcion_id: fila.id, tipo: 'tanda', cantidad: o.hechos, forzar: true,
        });
        fila.hechosGuardados = true;
      }
    }
  } catch (e) {
    try { await refrescarProductos(); } catch (_) { /* el error original es el que importa */ }
    throw e;
  }
  porId('dialogo-producto').close();
  anunciar('Producto actualizado');
  try {
    await refrescarProductos();
  } catch (e) {
    manejarError(e, 'error-productos');
  }
}

function conectarEventosProductos() {
  porId('boton-nuevo-producto').addEventListener('click', () => abrirDialogoProducto('nuevo'));
  porId('boton-editar-producto').addEventListener('click', () => abrirDialogoProducto('editar'));
  porId('form-producto').addEventListener('submit', guardarProducto);
  porId('producto-cancelar').addEventListener('click', () => porId('dialogo-producto').close());
  porId('agregar-opcion').addEventListener('click', () => {
    const fila = agregarFilaOpcion(null, false);
    if (fila) fila.nombre.focus();
  });

  const archivo = porId('producto-foto-archivo');
  porId('boton-foto-producto').addEventListener('click', () => archivo.click());
  archivo.addEventListener('change', () => { if (archivo.files[0]) subirFotoProducto(archivo.files[0]); archivo.value = ''; });

  porId('form-mov').addEventListener('submit', (ev) => { ev.preventDefault(); guardarMovimiento(false); });
  porId('mov-tipo').addEventListener('change', formularioMovCambio);
  porId('mov-opcion').addEventListener('change', formularioMovCambio);
  porId('mov-cantidad').addEventListener('input', formularioMovCambio);
  porId('mov-cuando').addEventListener('input', () => {
    prod.cuandoTocado = true;
    porId('mov-ahora').hidden = false;
    formularioMovCambio();
  });
  porId('mov-ahora').addEventListener('click', () => { ponerMovCuandoAhora(); formularioMovCambio(); });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !prod.cuandoTocado && prod.detalle) ponerMovCuandoAhora();
  });
}

/* =========================================================================
   12. Arranque
   ========================================================================= */

// La pestaña sale del hash (#productos...), así al recargar se vuelve a la misma.
function seccionDeHash() {
  return location.hash.startsWith('#productos') ? 'productos' : 'pedidos';
}

async function iniciarPanel() {
  const seccion = seccionDeHash();
  estado.seccion = seccion;
  porId('pantalla-panel').hidden = seccion !== 'pedidos';
  porId('pantalla-productos').hidden = seccion !== 'productos';
  porId('pestana-pedidos').setAttribute('aria-current', seccion === 'pedidos' ? 'page' : 'false');
  porId('pestana-productos').setAttribute('aria-current', seccion === 'productos' ? 'page' : 'false');
  const zonaError = seccion === 'productos' ? 'error-productos' : 'error-general';
  mostrarError(zonaError, '');
  try {
    if (seccion === 'productos') {
      await cargarProductos();
      await elegirProductoInicial();
    } else {
      await cargarPedidos();
      await elegirPedidoInicial();
    }
  } catch (e) {
    manejarError(e, zonaError);
  }
}

/* =========================================================================
   Usuarios: cuentas propias del sistema (solo las ve y crea el dueño)
   ========================================================================= */

async function dibujarUsuarios() {
  const lista = porId('lista-usuarios');
  vaciar(lista);
  const usuarios = await pedir('GET', '/api/usuarios');
  porId('sin-usuarios').hidden = usuarios.length > 0;
  for (const u of usuarios) {
    lista.append(crear('li', { clase: 'fila-usuario' },
      crear('span', { texto: u.correo }),
      crear('button', {
        type: 'button', clase: 'boton-secundario', texto: 'Quitar acceso',
        'aria-label': 'Quitar acceso a ' + u.correo,
        enclick: async () => {
          if (!confirm('¿Quitar el acceso a ' + u.correo + '? Se cerrará su sesión.')) return;
          try { await pedir('DELETE', '/api/usuarios/' + encodeURIComponent(u.correo)); await dibujarUsuarios(); }
          catch (e) { mostrarError('usuario-error', e.message); }
        },
      })));
  }
}

async function abrirUsuarios() {
  mostrarError('usuario-error', '');
  porId('usuario-correo').value = '';
  porId('usuario-clave').value = '';
  porId('dialogo-usuarios').showModal();
  try { await dibujarUsuarios(); } catch (e) { mostrarError('usuario-error', e.message); }
}

async function crearUsuario(ev) {
  ev.preventDefault();
  mostrarError('usuario-error', '');
  const boton = porId('usuario-crear');
  boton.disabled = true;
  try {
    await pedir('POST', '/api/usuarios', {
      correo: porId('usuario-correo').value.trim(),
      clave: porId('usuario-clave').value,
    });
    porId('usuario-correo').value = '';
    porId('usuario-clave').value = '';
    await dibujarUsuarios();
  } catch (e) {
    mostrarError('usuario-error', e.message);
  } finally {
    boton.disabled = false;
  }
}

function conectarEventos() {
  porId('boton-usuarios').addEventListener('click', abrirUsuarios);
  porId('usuarios-cerrar').addEventListener('click', () => porId('dialogo-usuarios').close());
  porId('form-usuario').addEventListener('submit', crearUsuario);
  porId('form-entrar').addEventListener('submit', entrar);
  porId('boton-salir').addEventListener('click', salir);

  porId('boton-nuevo').addEventListener('click', () => abrirDialogo('nuevo'));
  porId('boton-editar').addEventListener('click', () => abrirDialogo('editar'));
  porId('boton-terminar').addEventListener('click', marcarTerminado);
  porId('boton-terminados').addEventListener('click', () => {
    estado.verTerminados = !estado.verTerminados;
    dibujarLista();
  });

  porId('form-tanda').addEventListener('submit', (ev) => { ev.preventDefault(); guardarTanda(false); });
  porId('tanda-modelo').addEventListener('change', formularioCambio);
  porId('tanda-cantidad').addEventListener('input', formularioCambio);
  porId('tanda-cuando').addEventListener('input', () => {
    estado.cuandoTocado = true;
    porId('tanda-ahora').hidden = false;
    formularioCambio();
  });
  porId('tanda-ahora').addEventListener('click', () => { ponerCuandoAhora(); formularioCambio(); });
  // Al volver a la pestaña, "ahora" vuelve a ser ahora (no la hora en que se abrió).
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && !estado.cuandoTocado && estado.detalle) ponerCuandoAhora();
  });

  porId('historial-mas').addEventListener('click', () => {
    estado.tandasVisibles += TANDAS_POR_PAGINA;
    dibujarHistorial();
  });

  porId('form-pedido').addEventListener('submit', guardarPedido);
  porId('pedido-cancelar').addEventListener('click', () => porId('dialogo-pedido').close());
  porId('agregar-modelo').addEventListener('click', () => {
    const fila = agregarFila(null);
    if (fila) fila.nombre.focus();
  });

  conectarEventosProductos();

  window.addEventListener('hashchange', () => {
    if (porId('zona-sesion').hidden) return;
    // Cambio de pestaña: se recarga esa sección (puede haber cambios hechos desde el iPhone).
    if (seccionDeHash() !== estado.seccion) { iniciarPanel(); return; }
    if (estado.seccion === 'productos') {
      const id = idProductoDeHash();
      if (id && id !== prod.productoId) seleccionarProducto(id, { desplazar: true });
      return;
    }
    const id = idDeHash();
    if (id && id !== estado.pedidoId) seleccionar(id, { desplazar: true });
  });
}

async function arrancar() {
  conectarEventos();
  try {
    const yo = await pedir('GET', '/api/yo', undefined, { sinRedirigir: true });
    mostrarPanel(yo && yo.correo, yo && yo.dueno);
    await iniciarPanel();
  } catch (e) {
    if (e instanceof ErrorApi && e.estado === 401) mostrarEntrar('');
    else mostrarEntrar('No se pudo conectar con el servidor. Intenta de nuevo en un momento.');
  }
}

arrancar();
