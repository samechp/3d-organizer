"""
productos.py - Productos de catalogo, sus opciones y el stock de cada una.

Por opcion: saldo = tandas - ventas. Positivo es lo que hay en stock; negativo
es lo que falta imprimir (se vendio antes de tenerlo). El saldo se suma en SQL
cada vez, no se guarda.

Las piezas comunes (tipos validados, hora de Bogota, sesion) salen de
pedidos.py: asi un producto se comporta igual que un pedido en lo que comparten.
"""

import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import case, func, select
from sqlalchemy.exc import IntegrityError

from . import base, calculos, pedidos
from .acceso import usuario_actual

router = APIRouter(dependencies=[Depends(usuario_actual)])

MAX_OPCIONES = 50
ULTIMOS = 30
NOMBRE_REPETIDO = "Ya hay una opción con ese nombre en este producto"


# ---------------------------------------------------------------------------
# Validacion de lo que llega
# ---------------------------------------------------------------------------

class OpcionNueva(BaseModel):
    nombre: pedidos.NombreModelo
    # "¿Ya tienes hechos?": lo que ya hay en stock al crear el producto.
    hechos: Annotated[int, Field(strict=True, ge=0, le=100_000)] = 0


class ProductoNuevo(BaseModel):
    nombre: pedidos.Nombre
    opciones: list[OpcionNueva] = Field(min_length=1, max_length=MAX_OPCIONES)
    # Opcional: con el, crear dos veces lo mismo (reintento) da un solo producto.
    id_cliente: pedidos.IdCliente | None = None


class ProductoCambios(BaseModel):
    nombre: pedidos.Nombre


class OpcionNombre(BaseModel):
    nombre: pedidos.NombreModelo


class MovimientoNuevo(BaseModel):
    opcion_id: pedidos.IdEnBody
    tipo: Literal["venta", "tanda"]
    cantidad: pedidos.Cantidad
    cuando: pedidos.Cuando | None = None
    id_cliente: pedidos.IdCliente
    forzar: bool = False


# Mismos campos y reglas que corregir una tanda.
MovimientoCambios = pedidos.TandaCambios


# ---------------------------------------------------------------------------
# Piezas para armar las respuestas
# ---------------------------------------------------------------------------

def _movimiento_json(fila) -> dict:
    return {
        "id": fila.id, "opcion_id": fila.opcion_id, "opcion": fila.opcion, "tipo": fila.tipo,
        "cantidad": fila.cantidad, "cuando": pedidos._hora(fila.cuando), "id_cliente": fila.id_cliente,
    }


def _movimientos_con_producto():
    return (base.movimientos.join(base.opciones, base.opciones.c.id == base.movimientos.c.opcion_id)
            .join(base.productos, base.productos.c.id == base.opciones.c.producto_id))


def _consulta_movimientos(correo: str):
    return select(
        base.movimientos.c.id, base.movimientos.c.opcion_id, base.opciones.c.nombre.label("opcion"),
        base.movimientos.c.tipo, base.movimientos.c.cantidad, base.movimientos.c.cuando,
        base.movimientos.c.id_cliente,
    ).select_from(_movimientos_con_producto()).where(base.productos.c.dueno == correo)


def _recientes_primero(consulta):
    # id desc desempata movimientos con la misma hora: el anotado despues va primero.
    return consulta.order_by(base.movimientos.c.cuando.desc(), base.movimientos.c.id.desc())


def _opciones_por_producto(con, producto_ids: list[int]) -> dict[int, list[dict]]:
    """Opciones de varios productos con su saldo, en una sola consulta.

    El outer join deja en 0 las opciones sin movimientos en vez de perderlas.
    """
    if not producto_ids:
        return {}
    m = base.movimientos.c
    saldo = func.coalesce(func.sum(case((m.tipo == "tanda", m.cantidad), else_=-m.cantidad)), 0)
    filas = con.execute(
        select(base.opciones, saldo.label("saldo"))
        .select_from(base.opciones.outerjoin(base.movimientos, m.opcion_id == base.opciones.c.id))
        .where(base.opciones.c.producto_id.in_(producto_ids))
        .group_by(*base.opciones.c)
        .order_by(base.opciones.c.orden, base.opciones.c.id)
    ).all()
    por_producto: dict[int, list[dict]] = {i: [] for i in producto_ids}
    for f in filas:
        # int(): MySQL devuelve SUM como Decimal.
        por_producto[f.producto_id].append({"id": f.id, "nombre": f.nombre, "saldo": int(f.saldo)})
    return por_producto


def _resumen_json(producto, opciones: list[dict]) -> dict:
    return {
        "id": producto.id, "nombre": producto.nombre,
        "foto_url": f"/api/fotos/{producto.foto}" if producto.foto else None,
        "opciones": opciones,
        # Se suman por separado: lo que sobra de una opcion no tapa lo que falta de otra.
        "faltan": sum(-o["saldo"] for o in opciones if o["saldo"] < 0),
        "stock": sum(o["saldo"] for o in opciones if o["saldo"] > 0),
    }


def _producto_o_404(con, producto_id: int, correo: str):
    # Lo de otra cuenta responde igual que lo que no existe.
    fila = con.execute(select(base.productos).where(
        base.productos.c.id == producto_id, base.productos.c.dueno == correo)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese producto")
    return fila


def _detalle(con, producto_id: int, correo: str) -> dict:
    producto = _producto_o_404(con, producto_id, correo)
    ultimos = con.execute(_recientes_primero(
        _consulta_movimientos(correo).where(base.opciones.c.producto_id == producto_id)).limit(ULTIMOS)).all()
    return {
        **_resumen_json(producto, _opciones_por_producto(con, [producto_id])[producto_id]),
        "movimientos": [_movimiento_json(f) for f in ultimos],
    }


def _opcion_o_404(con, opcion_id: int, correo: str):
    fila = con.execute(
        select(base.opciones)
        .select_from(base.opciones.join(base.productos, base.productos.c.id == base.opciones.c.producto_id))
        .where(base.opciones.c.id == opcion_id, base.productos.c.dueno == correo)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe esa opción")
    return fila


def _opcion_con_saldo(con, opcion_id: int, correo: str) -> dict:
    fila = _opcion_o_404(con, opcion_id, correo)
    return next(o for o in _opciones_por_producto(con, [fila.producto_id])[fila.producto_id]
                if o["id"] == opcion_id)


def _movimiento_o_404(con, movimiento_id: int, correo: str):
    fila = con.execute(_consulta_movimientos(correo).where(base.movimientos.c.id == movimiento_id)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese movimiento")
    return fila


def _buscar_por_id_cliente(con, id_cliente: str, correo: str):
    # Como en tandas: un id_cliente de otra cuenta es conflicto, sin datos de ella.
    dueno = con.execute(select(base.productos.c.dueno).select_from(_movimientos_con_producto())
                        .where(base.movimientos.c.id_cliente == id_cliente)).scalar()
    if dueno is None:
        return None
    if dueno != correo:
        raise HTTPException(status_code=409, detail="Ese id_cliente ya está en uso")
    return con.execute(_consulta_movimientos(correo).where(base.movimientos.c.id_cliente == id_cliente)).first()


# ---------------------------------------------------------------------------
# Productos
# ---------------------------------------------------------------------------

@router.get("/api/productos")
def listar_productos(request: Request, correo: pedidos.Correo):
    with request.app.state.motor_sistema.connect() as con:
        filas = con.execute(select(base.productos).where(base.productos.c.dueno == correo)
                            .order_by(base.productos.c.nombre, base.productos.c.id)).all()
        opciones = _opciones_por_producto(con, [p.id for p in filas])
    return [_resumen_json(p, opciones[p.id]) for p in filas]


def _producto_por_id_cliente(con, id_cliente: str | None, correo: str) -> int | None:
    """Id del producto ya creado con ese id_cliente, o None.

    Como en movimientos: el de otra cuenta es conflicto, sin datos de ella.
    """
    if id_cliente is None:
        return None
    fila = con.execute(select(base.productos.c.id, base.productos.c.dueno)
                       .where(base.productos.c.id_cliente == id_cliente)).first()
    if fila is None:
        return None
    if fila.dueno != correo:
        raise HTTPException(status_code=409, detail="Ese id_cliente ya está en uso")
    return fila.id


@router.post("/api/productos", status_code=201)
def crear_producto(datos: ProductoNuevo, request: Request, response: Response, correo: pedidos.Correo):
    ahora = pedidos.ahora_bogota()
    motor = request.app.state.motor_sistema
    try:
        with motor.begin() as con:
            existente = _producto_por_id_cliente(con, datos.id_cliente, correo)
            if existente is not None:
                response.status_code = 200
                return _detalle(con, existente, correo)
            producto_id = con.execute(base.productos.insert().values(
                dueno=correo, nombre=datos.nombre, creado=ahora,
                id_cliente=datos.id_cliente)).inserted_primary_key[0]
            for i, o in enumerate(datos.opciones):
                opcion_id = con.execute(base.opciones.insert().values(
                    producto_id=producto_id, nombre=o.nombre, orden=i)).inserted_primary_key[0]
                if o.hechos:
                    # Lo que ya habia es una tanda inicial: asi el saldo sale de la
                    # misma suma de siempre y se puede corregir como cualquier otra.
                    con.execute(base.movimientos.insert().values(
                        opcion_id=opcion_id, tipo="tanda", cantidad=o.hechos, cuando=ahora,
                        id_cliente=str(uuid.uuid4()), creada=ahora))
            return _detalle(con, producto_id, correo)
    except IntegrityError:
        # Dos envios del mismo producto a la vez: al perdedor se le da el ganador.
        # Si no, lo que choco fueron dos opciones con el mismo nombre.
        with motor.connect() as con:
            existente = _producto_por_id_cliente(con, datos.id_cliente, correo)
            if existente is not None:
                response.status_code = 200
                return _detalle(con, existente, correo)
        raise HTTPException(status_code=409, detail=NOMBRE_REPETIDO)


@router.get("/api/productos/{producto_id}")
def ver_producto(producto_id: pedidos.IdRuta, request: Request, correo: pedidos.Correo):
    with request.app.state.motor_sistema.connect() as con:
        return _detalle(con, producto_id, correo)


@router.patch("/api/productos/{producto_id}")
def editar_producto(producto_id: pedidos.IdRuta, datos: ProductoCambios, request: Request,
                    correo: pedidos.Correo):
    with request.app.state.motor_sistema.begin() as con:
        _producto_o_404(con, producto_id, correo)
        con.execute(base.productos.update().where(base.productos.c.id == producto_id)
                    .values(nombre=datos.nombre))
        return _detalle(con, producto_id, correo)


# ---------------------------------------------------------------------------
# Opciones
# ---------------------------------------------------------------------------

@router.post("/api/productos/{producto_id}/opciones", status_code=201)
def agregar_opcion(producto_id: pedidos.IdRuta, datos: OpcionNombre, request: Request,
                   correo: pedidos.Correo):
    try:
        with request.app.state.motor_sistema.begin() as con:
            _producto_o_404(con, producto_id, correo)
            cuantas, ultimo = con.execute(
                select(func.count(), func.coalesce(func.max(base.opciones.c.orden), -1))
                .where(base.opciones.c.producto_id == producto_id)).one()
            if cuantas >= MAX_OPCIONES:
                raise HTTPException(status_code=409, detail=f"Un producto admite hasta {MAX_OPCIONES} opciones")
            opcion_id = con.execute(base.opciones.insert().values(
                producto_id=producto_id, nombre=datos.nombre, orden=ultimo + 1)).inserted_primary_key[0]
            return _opcion_con_saldo(con, opcion_id, correo)
    except IntegrityError:
        raise HTTPException(status_code=409, detail=NOMBRE_REPETIDO)


@router.patch("/api/opciones/{opcion_id}")
def editar_opcion(opcion_id: pedidos.IdRuta, datos: OpcionNombre, request: Request,
                  correo: pedidos.Correo):
    try:
        with request.app.state.motor_sistema.begin() as con:
            _opcion_o_404(con, opcion_id, correo)
            con.execute(base.opciones.update().where(base.opciones.c.id == opcion_id)
                        .values(nombre=datos.nombre))
            return _opcion_con_saldo(con, opcion_id, correo)
    except IntegrityError:
        raise HTTPException(status_code=409, detail=NOMBRE_REPETIDO)


@router.delete("/api/opciones/{opcion_id}", status_code=204)
def borrar_opcion(opcion_id: pedidos.IdRuta, request: Request, correo: pedidos.Correo):
    with request.app.state.motor_sistema.begin() as con:
        _opcion_o_404(con, opcion_id, correo)
        # Borrarla con movimientos haria desaparecer ventas y tandas del historial.
        tiene = con.execute(select(base.movimientos.c.id)
                            .where(base.movimientos.c.opcion_id == opcion_id).limit(1)).first()
        if tiene:
            raise HTTPException(status_code=409, detail="La opción ya tiene movimientos; bórralos primero")
        con.execute(base.opciones.delete().where(base.opciones.c.id == opcion_id))
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Movimientos
# ---------------------------------------------------------------------------

@router.get("/api/productos/{producto_id}/movimientos")
def listar_movimientos(producto_id: pedidos.IdRuta, request: Request, correo: pedidos.Correo,
                       opcion_id: Annotated[int | None, Field(ge=1, le=pedidos.MAX_ID)] = None):
    with request.app.state.motor_sistema.connect() as con:
        _producto_o_404(con, producto_id, correo)
        consulta = _consulta_movimientos(correo).where(base.opciones.c.producto_id == producto_id)
        if opcion_id is not None:
            consulta = consulta.where(base.movimientos.c.opcion_id == opcion_id)
        filas = con.execute(_recientes_primero(consulta)).all()
    return [_movimiento_json(f) for f in filas]


@router.post("/api/movimientos", status_code=201)
def crear_movimiento(datos: MovimientoNuevo, request: Request, response: Response,
                     correo: pedidos.Correo):
    motor = request.app.state.motor_sistema
    try:
        with motor.begin() as con:
            # Primero el reintento: nunca un 409 de "parecida" contra si mismo.
            existente = _buscar_por_id_cliente(con, datos.id_cliente, correo)
            if existente:
                response.status_code = 200
                return _movimiento_json(existente)

            _opcion_o_404(con, datos.opcion_id, correo)
            cuando = datos.cuando or pedidos.ahora_bogota()
            m = base.movimientos.c

            # Solo las tandas: dos ventas iguales seguidas son normales (dos
            # clientes piden lo mismo); dos tandas iguales seguidas suelen ser
            # la misma anotada dos veces.
            if datos.tipo == "tanda" and not datos.forzar:
                candidata = con.execute(
                    select(m.id, m.cantidad, m.cuando)
                    .where(m.opcion_id == datos.opcion_id, m.tipo == "tanda",
                           m.cantidad == datos.cantidad,
                           m.cuando.between(cuando - calculos.VENTANA_PARECIDA,
                                            cuando + calculos.VENTANA_PARECIDA))
                    .order_by(m.cuando.desc(), m.id.desc()).limit(1)
                ).first()
                if candidata and calculos.es_parecida(datos.cantidad, cuando,
                                                      candidata.cantidad, candidata.cuando):
                    return JSONResponse(status_code=409, content={"parecida": {
                        "id": candidata.id, "cantidad": candidata.cantidad,
                        "cuando": pedidos._hora(candidata.cuando),
                        "hace_minutos": int(abs(cuando - candidata.cuando).total_seconds() // 60),
                    }})

            movimiento_id = con.execute(base.movimientos.insert().values(
                opcion_id=datos.opcion_id, tipo=datos.tipo, cantidad=datos.cantidad, cuando=cuando,
                id_cliente=datos.id_cliente, creada=pedidos.ahora_bogota(),
            )).inserted_primary_key[0]
            return _movimiento_json(_movimiento_o_404(con, movimiento_id, correo))
    except IntegrityError:
        # Dos envios del mismo movimiento a la vez: al perdedor se le da el ganador.
        with motor.connect() as con:
            existente = _buscar_por_id_cliente(con, datos.id_cliente, correo)
        if existente is None:
            raise HTTPException(status_code=404, detail="No existe esa opción")
        response.status_code = 200
        return _movimiento_json(existente)


@router.patch("/api/movimientos/{movimiento_id}")
def editar_movimiento(movimiento_id: pedidos.IdRuta, datos: MovimientoCambios, request: Request,
                      correo: pedidos.Correo):
    cambios = datos.model_dump(exclude_unset=True)
    with request.app.state.motor_sistema.begin() as con:
        _movimiento_o_404(con, movimiento_id, correo)
        if cambios:
            con.execute(base.movimientos.update().where(base.movimientos.c.id == movimiento_id)
                        .values(**cambios))
        return _movimiento_json(_movimiento_o_404(con, movimiento_id, correo))


@router.delete("/api/movimientos/{movimiento_id}", status_code=204)
def borrar_movimiento(movimiento_id: pedidos.IdRuta, request: Request, correo: pedidos.Correo):
    with request.app.state.motor_sistema.begin() as con:
        _movimiento_o_404(con, movimiento_id, correo)
        con.execute(base.movimientos.delete().where(base.movimientos.c.id == movimiento_id))
    return Response(status_code=204)
