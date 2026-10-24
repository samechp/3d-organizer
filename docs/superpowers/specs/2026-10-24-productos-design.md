# Productos (stock por opción) — diseño

Fecha: 2026-10-24 · Estado: aprobado por Juan (maqueta artboards 10–13 + Web · Productos en
https://claude.ai/artifact/5KcGFtKRC11LSiUgbu75EV)

## Por qué
Además de los pedidos grandes, Juan y su amigo venden productos de catálogo que se venden
poco a poco (por su página o por WhatsApp), con opciones (colores, etc.). Quieren llevar la
cuenta: lo que imprimen suma, lo que venden resta. Sin clientes, sin precios, sin
integraciones: se anota a mano.

## Regla
Por opción: **saldo = Σ tandas − Σ ventas**. Saldo > 0 → "N en stock"; saldo < 0 →
"Faltan N" (por imprimir); 0 → "0". Cada cuenta ve solo lo suyo (columna `dueno`, igual que
pedidos).

## Datos (servidor)
- `productos(id, dueno [DUENO], nombre String(120), foto String(80) NULL, creado)`
- `opciones(id, producto_id FK, nombre String(80), orden int)` — nombre único por producto.
- `movimientos(id, opcion_id FK, tipo 'venta'|'tanda', cantidad int 1–100000, cuando DATETIME
  (hora Bogotá sin zona, como tandas), id_cliente CHAR(36) UNIQUE, creada)`
- "Ya tienes hechos" al crear = un movimiento `tanda` inicial por opción.

## API (todas con sesión; lo ajeno = 404)
- `GET /api/productos` → `[{id, nombre, foto_url, opciones:[{id, nombre, saldo}], faltan, stock}]`
  (`faltan` = Σ de saldos negativos en positivo; `stock` = Σ saldos positivos).
- `POST /api/productos {nombre, opciones:[{nombre, hechos?}]}` → detalle (201).
- `GET /api/productos/{id}` → `{id, nombre, foto_url, opciones:[…], faltan, stock,
  movimientos:[últimos 30: {id, opcion_id, opcion, tipo, cantidad, cuando, id_cliente}]}`.
- `PATCH /api/productos/{id} {nombre}` · `PUT /api/productos/{id}/foto` (como modelos).
- `POST /api/productos/{id}/opciones {nombre}` · `PATCH /api/opciones/{id} {nombre}` ·
  `DELETE /api/opciones/{id}` (409 si tiene movimientos).
- `GET /api/productos/{id}/movimientos?opcion_id=`.
- `POST /api/movimientos {opcion_id, tipo, cantidad, cuando?, id_cliente, forzar=false}`:
  idempotente por id_cliente (como tandas); aviso de repetida **solo para tipo tanda** (misma
  opción, misma cantidad, ±3 h) → 409 `{"parecida": {...}}`.
- `PATCH /api/movimientos/{id} {cantidad?, cuando?}` · `DELETE /api/movimientos/{id}`.
- Fotos: `GET /api/fotos/{nombre}` también sirve fotos de productos propios.

## Pantallas
Como la maqueta: pestaña Productos (iPhone, entre Pedidos y Calculadora) con "Por imprimir"
ordenado por faltan y la lista de productos; detalle con opciones, "− Venta" de un toque y
"+ Tanda" que abre la hoja; hoja Anotar (Venta/Tanda, opción, cantidad, rápidas, fecha,
vista previa antes→después); nuevo/editar producto con opciones y "¿ya tienes hechos?";
movimientos tocables para corregir/borrar. Web: pestaña Productos al lado de Pedidos.
Sin señal: los movimientos se encolan igual que las tandas.

## Fuera
Clientes, precios, borrar productos, integraciones con Telegram/WhatsApp.
