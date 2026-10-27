"""
pedidos.py - Pedidos, modelos y tandas.

Un pedido tiene modelos (cada uno con su meta) y cada modelo suma tandas: lo
que Juan va sacando de la impresora. Las sumas se hacen en SQL, no trayendo
todas las tandas a Python.

Las fechas se guardan como hora de Bogota sin zona (DATETIME) y se entregan
con su desfase (-05:00). Colombia no tiene horario de verano, asi que el
desfase es siempre el mismo y la hora guardada no se presta a confusion.
"""

import uuid
from datetime import date, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Path, Request, Response
from fastapi.responses import JSONResponse
from pydantic import (
    AfterValidator, BaseModel, BeforeValidator, Field, StringConstraints, field_validator,
    model_validator,
)
from sqlalchemy import case, func, select
from sqlalchemy.exc import IntegrityError

from . import base, calculos
from .acceso import usuario_actual

# Todas las rutas piden sesion: se declara una vez aqui y no se puede olvidar
# en una ruta nueva.
router = APIRouter(dependencies=[Depends(usuario_actual)])

# Correo de quien llama, para filtrar por dueno. FastAPI guarda el resultado de
# la dependencia por peticion: la sesion no se valida dos veces.
Correo = Annotated[str, Depends(usuario_actual)]

BOGOTA = ZoneInfo("America/Bogota")
MAX_MODELOS = 50
ULTIMAS = 5

# Tope de las columnas INT de MySQL: un id mas grande reventaria la consulta
# (500) en vez de dar un 404 o un 422.
MAX_ID = 2_147_483_647


def ahora_bogota() -> datetime:
    """Hora actual en Bogota, sin zona y sin fracciones de segundo.

    Es la unica fuente de "ahora": las pruebas la reemplazan para fijar la hora.
    """
    return datetime.now(BOGOTA).replace(tzinfo=None, microsecond=0)


# ---------------------------------------------------------------------------
# Validacion de lo que llega
# ---------------------------------------------------------------------------

def _solo_texto(valor):
    # Pydantic aceptaria tambien un numero como fecha (segundos desde 1970);
    # aqui una fecha tiene que ser texto ISO 8601.
    if not isinstance(valor, str):
        raise ValueError("Debe ser una fecha en texto ISO 8601")
    return valor


def _en_rango(valor):
    # Fechas absurdas (año 1, año 9999) no caben en el DATETIME de MySQL y
    # serian un 500; mejor un 422.
    if not 2000 <= valor.year <= 2100:
        raise ValueError("Fecha fuera de rango")
    return valor


def _cuando_a_bogota(valor: datetime) -> datetime:
    # Con zona se convierte a Bogota; sin zona se toma como Bogota (asi la
    # escribe quien teclea la hora a mano en la web).
    if valor.tzinfo is not None:
        try:
            valor = valor.astimezone(BOGOTA).replace(tzinfo=None)
        except OverflowError:
            # En los extremos del calendario (año 1, año 9999) convertir de zona se
            # sale de lo que datetime soporta; Pydantic solo traduce ValueError a
            # 422, y un OverflowError seria un 500.
            raise ValueError("Fecha fuera de rango")
    return _en_rango(valor.replace(microsecond=0))


def _uuid_canonico(valor: str) -> str:
    # Minusculas y con guiones: el iPhone manda mayusculas, y un reintento tiene
    # que reconocerse como la misma tanda sin importar como se escriba.
    try:
        return str(uuid.UUID(valor))
    except ValueError:
        raise ValueError("Debe ser un UUID")


Cuando = Annotated[datetime, BeforeValidator(_solo_texto), AfterValidator(_cuando_a_bogota)]
Entrega = Annotated[date, BeforeValidator(_solo_texto), AfterValidator(_en_rango)]
IdCliente = Annotated[str, StringConstraints(max_length=64), AfterValidator(_uuid_canonico)]
# strict: que 5 sea 5 y no "5", 5.0 ni true.
IdEnBody = Annotated[int, Field(strict=True, ge=1, le=MAX_ID)]
Cantidad = Annotated[int, Field(strict=True, ge=1, le=100_000)]
Meta = Annotated[int, Field(strict=True, ge=1, le=1_000_000)]
Nombre = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
# modelos.nombre mide 80 en la base: un nombre mas largo no cabria.
NombreModelo = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
Cliente = Annotated[str, StringConstraints(strip_whitespace=True, max_length=120)]
Nota = Annotated[str, StringConstraints(strip_whitespace=True, max_length=5000)]
IdRuta = Annotated[int, Path(ge=1, le=MAX_ID)]


class ModeloNuevo(BaseModel):
    # Nuevo: nombre + meta, se imprime por tandas. Del stock: opcion_id + meta,
    # sale de esa opcion de Productos (el nombre, si no viene, es "Producto · Opción").
    nombre: NombreModelo | None = None
    meta: Meta
    opcion_id: IdEnBody | None = None

    @model_validator(mode="after")
    def _nombre_u_opcion(self):
        if self.nombre is None and self.opcion_id is None:
            raise ValueError("Falta el nombre del modelo")
        return self


class PedidoNuevo(BaseModel):
    nombre: Nombre
    cliente: Cliente | None = None
    entrega: Entrega | None = None
    nota: Nota | None = None
    modelos: list[ModeloNuevo] = Field(min_length=1, max_length=MAX_MODELOS)

    @field_validator("cliente", "nota")
    @classmethod
    def _vacio_es_nulo(cls, v):
        return v or None


class PedidoCambios(BaseModel):
    # Lo que no se manda no se toca; mandar null en cliente/entrega/nota lo borra.
    nombre: Nombre | None = None
    cliente: Cliente | None = None
    entrega: Entrega | None = None
    nota: Nota | None = None
    estado: Literal["abierto", "terminado"] | None = None

    @field_validator("nombre", "estado")
    @classmethod
    def _no_nulo(cls, v):
        # Estos dos no se pueden borrar: null explicito es un error.
        if v is None:
            raise ValueError("No puede ser null")
        return v

    @field_validator("cliente", "nota")
    @classmethod
    def _vacio_es_nulo(cls, v):
        return v or None


class ModeloCambios(BaseModel):
    nombre: NombreModelo | None = None
    meta: Meta | None = None
    # Solo para rechazarlo con un mensaje claro: cambiar de opcion moveria la
    # venta de un producto a otro sin que se note en ninguno de los dos.
    opcion_id: int | None = None

    @field_validator("nombre", "meta")
    @classmethod
    def _no_nulo(cls, v):
        if v is None:
            raise ValueError("No puede ser null")
        return v

    @field_validator("opcion_id", mode="before")
    @classmethod
    def _opcion_fija(cls, v):
        raise ValueError("El producto de un modelo del stock no se cambia: borra el modelo y agrégalo de nuevo")


class TandaNueva(BaseModel):
    modelo_id: IdEnBody
    cantidad: Cantidad
    cuando: Cuando | None = None
    id_cliente: IdCliente
    forzar: bool = False


class TandaCambios(BaseModel):
    cantidad: Cantidad | None = None
    cuando: Cuando | None = None

    @field_validator("cantidad", "cuando")
    @classmethod
    def _no_nulo(cls, v):
        if v is None:
            raise ValueError("No puede ser null")
        return v


# ---------------------------------------------------------------------------
# Piezas para armar las respuestas
# ---------------------------------------------------------------------------

def _hora(valor: datetime | None) -> str | None:
    # '2026-10-23T15:02:00-05:00': la app y la web lo leen sin adivinar la zona.
    return valor.replace(tzinfo=BOGOTA).isoformat() if valor else None


def _tanda_json(fila) -> dict:
    return {
        "id": fila.id, "modelo_id": fila.modelo_id, "modelo": fila.modelo,
        "cantidad": fila.cantidad, "cuando": _hora(fila.cuando), "id_cliente": fila.id_cliente,
    }


def _tandas_con_pedido():
    # La tanda no guarda dueno: se llega a el por su modelo y el pedido de este.
    return (base.tandas.join(base.modelos, base.modelos.c.id == base.tandas.c.modelo_id)
            .join(base.pedidos, base.pedidos.c.id == base.modelos.c.pedido_id))


def _consulta_tandas(correo: str):
    # El nombre del modelo va en cada tanda para que las listas no tengan que
    # cruzar datos ni hacer una consulta por tanda.
    return select(
        base.tandas.c.id, base.tandas.c.modelo_id, base.modelos.c.nombre.label("modelo"),
        base.tandas.c.cantidad, base.tandas.c.cuando, base.tandas.c.id_cliente,
    ).select_from(_tandas_con_pedido()).where(base.pedidos.c.dueno == correo)


def _modelo_json(fila, hechas: int, del_stock: dict | None = None) -> dict:
    if fila.opcion_id is not None:
        # Del stock: ya salio de Productos, asi que cuenta como hecho. Si alli
        # falta stock, lo dice del_stock.saldo; el pedido no lo vuelve a contar.
        hechas = fila.meta
    return {
        "id": fila.id, "nombre": fila.nombre, "meta": fila.meta, "hechas": hechas,
        "opcion_id": fila.opcion_id, "del_stock": del_stock,
        "foto_url": f"/api/fotos/{fila.foto}" if fila.foto else None,
        "completo": hechas >= fila.meta,
        # Pasarse de la meta es normal (sobran piezas de prueba o de repuesto):
        # se muestra cuanto, no se rechaza.
        "de_mas": max(0, hechas - fila.meta),
        "faltan": max(0, fila.meta - hechas),
    }


def _del_stock(con, opcion_ids: list[int]) -> dict[int, dict]:
    """Producto, opcion y saldo actual de las opciones de modelos del stock.

    Sin filtro de dueno: los opcion_id salen de modelos ya filtrados por su
    pedido, y al crearlos se comprobo que la opcion era de la misma cuenta.
    """
    if not opcion_ids:
        return {}
    m = base.movimientos.c
    saldo = func.coalesce(func.sum(case((m.tipo == "tanda", m.cantidad), else_=-m.cantidad)), 0)
    filas = con.execute(
        select(base.opciones.c.id, base.opciones.c.nombre, base.productos.c.id.label("producto_id"),
               base.productos.c.nombre.label("producto"), saldo.label("saldo"))
        .select_from(base.opciones
                     .join(base.productos, base.productos.c.id == base.opciones.c.producto_id)
                     .outerjoin(base.movimientos, m.opcion_id == base.opciones.c.id))
        .where(base.opciones.c.id.in_(set(opcion_ids)))
        .group_by(base.opciones.c.id, base.opciones.c.nombre, base.productos.c.id, base.productos.c.nombre)
    ).all()
    return {f.id: {"producto_id": f.producto_id, "producto": f.producto, "opcion": f.nombre,
                   "saldo": int(f.saldo)} for f in filas}


def _opcion_o_404(con, opcion_id: int, correo: str):
    # Aqui y no importando productos.py, que ya importa este modulo.
    fila = con.execute(
        select(base.opciones.c.id, base.opciones.c.nombre, base.productos.c.nombre.label("producto"))
        .select_from(base.opciones.join(base.productos, base.productos.c.id == base.opciones.c.producto_id))
        .where(base.opciones.c.id == opcion_id, base.productos.c.dueno == correo)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe esa opción")
    return fila


def _insertar_modelo(con, pedido_id: int, datos: ModeloNuevo, orden: int, correo: str) -> int:
    """Inserta un modelo; si es del stock, tambien la venta que lo descuenta.

    Va en la misma transaccion que el pedido: nunca queda un modelo del stock
    sin su venta ni una venta sin su modelo.
    """
    nombre = datos.nombre
    if datos.opcion_id is not None:
        opcion = _opcion_o_404(con, datos.opcion_id, correo)
        # modelos.nombre mide 80; producto + opcion pueden pasarse.
        nombre = nombre or f"{opcion.producto} · {opcion.nombre}"[:80]
    modelo_id = con.execute(base.modelos.insert().values(
        pedido_id=pedido_id, nombre=nombre, meta=datos.meta, orden=orden, opcion_id=datos.opcion_id,
    )).inserted_primary_key[0]
    if datos.opcion_id is not None:
        ahora = ahora_bogota()
        # Si no alcanza el stock, el saldo queda negativo: Productos lo muestra como "faltan".
        con.execute(base.movimientos.insert().values(
            opcion_id=datos.opcion_id, tipo="venta", cantidad=datos.meta, cuando=ahora,
            id_cliente=str(uuid.uuid4()), creada=ahora, modelo_id=modelo_id))
    return modelo_id


def _modelos_por_pedido(con, pedido_ids: list[int]) -> dict[int, list[dict]]:
    """Modelos de varios pedidos con lo hecho de cada uno, en una sola consulta.

    La suma se hace en SQL con GROUP BY; el outer join deja los modelos sin
    tandas con 0 en vez de desaparecer.
    """
    if not pedido_ids:
        return {}
    suma = func.coalesce(func.sum(base.tandas.c.cantidad), 0)
    filas = con.execute(
        select(base.modelos, suma.label("hechas"))
        .select_from(base.modelos.outerjoin(base.tandas, base.tandas.c.modelo_id == base.modelos.c.id))
        .where(base.modelos.c.pedido_id.in_(pedido_ids))
        .group_by(*base.modelos.c)
        .order_by(base.modelos.c.orden, base.modelos.c.id)
    ).all()
    stock = _del_stock(con, [f.opcion_id for f in filas if f.opcion_id is not None])
    por_pedido: dict[int, list[dict]] = {i: [] for i in pedido_ids}
    for f in filas:
        # int(): MySQL devuelve SUM como Decimal.
        por_pedido[f.pedido_id].append(_modelo_json(f, int(f.hechas), stock.get(f.opcion_id)))
    return por_pedido


def _avance_y_ritmo(pedido, modelos: list[dict]) -> tuple[dict, dict | None]:
    av = calculos.avance([(m["hechas"], m["meta"]) for m in modelos])
    # Un pedido cerrado ya no reparte nada: sin ritmo, y asi tampoco sale
    # "vencido" en uno que se cerro hace meses.
    if pedido.estado == "terminado":
        return av, None
    return av, calculos.ritmo(av["faltan"], pedido.entrega, ahora_bogota().date())


def _resumen_json(pedido, modelos: list[dict]) -> dict:
    av, rit = _avance_y_ritmo(pedido, modelos)
    return {
        "id": pedido.id, "nombre": pedido.nombre, "cliente": pedido.cliente,
        "entrega": pedido.entrega.isoformat() if pedido.entrega else None,
        "estado": pedido.estado, "num_modelos": len(modelos), "avance": av, "ritmo": rit,
    }


def _pedido_o_404(con, pedido_id: int, correo: str):
    # El pedido de otra cuenta responde igual que uno que no existe: ni siquiera
    # se deja saber que ese id esta ocupado.
    fila = con.execute(select(base.pedidos).where(
        base.pedidos.c.id == pedido_id, base.pedidos.c.dueno == correo)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese pedido")
    return fila


def _detalle(con, pedido_id: int, correo: str) -> dict:
    pedido = _pedido_o_404(con, pedido_id, correo)
    modelos = _modelos_por_pedido(con, [pedido_id])[pedido_id]
    ultimas = con.execute(
        _consulta_tandas(correo).where(base.modelos.c.pedido_id == pedido_id)
        # id desc desempata tandas con la misma hora: la anotada despues va primero.
        .order_by(base.tandas.c.cuando.desc(), base.tandas.c.id.desc()).limit(ULTIMAS)
    ).all()
    return {
        **_resumen_json(pedido, modelos),
        "nota": pedido.nota,
        "terminado_en": _hora(pedido.terminado_en),
        "modelos": modelos,
        "ultimas_tandas": [_tanda_json(t) for t in ultimas],
    }


def _modelo_o_404(con, modelo_id: int, correo: str):
    fila = con.execute(
        select(base.modelos)
        .select_from(base.modelos.join(base.pedidos, base.pedidos.c.id == base.modelos.c.pedido_id))
        .where(base.modelos.c.id == modelo_id, base.pedidos.c.dueno == correo)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese modelo")
    return fila


def _modelo_con_hechas(con, modelo_id: int, correo: str) -> dict:
    fila = _modelo_o_404(con, modelo_id, correo)
    hechas = con.execute(
        select(func.coalesce(func.sum(base.tandas.c.cantidad), 0))
        .where(base.tandas.c.modelo_id == modelo_id)
    ).scalar()
    stock = _del_stock(con, [fila.opcion_id] if fila.opcion_id is not None else [])
    return _modelo_json(fila, int(hechas), stock.get(fila.opcion_id))


def _tanda_o_404(con, tanda_id: int, correo: str):
    fila = con.execute(_consulta_tandas(correo).where(base.tandas.c.id == tanda_id)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe esa tanda")
    return fila


def _buscar_por_id_cliente(con, id_cliente: str, correo: str):
    # id_cliente es UNIQUE en toda la tabla. Si ya lo uso otra cuenta (un UUID
    # repetido no pasa por azar) es un conflicto, sin devolver nada de esa tanda.
    dueno = con.execute(select(base.pedidos.c.dueno).select_from(_tandas_con_pedido())
                        .where(base.tandas.c.id_cliente == id_cliente)).scalar()
    if dueno is None:
        return None
    if dueno != correo:
        raise HTTPException(status_code=409, detail="Ese id_cliente ya está en uso")
    return con.execute(_consulta_tandas(correo).where(base.tandas.c.id_cliente == id_cliente)).first()


# ---------------------------------------------------------------------------
# Pedidos
# ---------------------------------------------------------------------------

@router.get("/api/pedidos")
def listar_pedidos(request: Request, correo: Correo,
                   estado: Literal["abierto", "terminado"] | None = None):
    consulta = select(base.pedidos).where(base.pedidos.c.dueno == correo)
    if estado:
        consulta = consulta.where(base.pedidos.c.estado == estado)
    with request.app.state.motor_sistema.connect() as con:
        filas = con.execute(consulta).all()
        modelos = _modelos_por_pedido(con, [p.id for p in filas])

    # Abiertos primero y, entre ellos, el que entrega antes; sin fecha al final.
    # Los terminados, el cerrado mas recientemente primero.
    def orden(p):
        if p.estado == "terminado":
            return (1, 0, -(p.terminado_en.timestamp() if p.terminado_en else 0), -p.id)
        return (0, p.entrega is None, p.entrega.toordinal() if p.entrega else 0, -p.id)

    return [_resumen_json(p, modelos[p.id]) for p in sorted(filas, key=orden)]


@router.post("/api/pedidos", status_code=201)
def crear_pedido(datos: PedidoNuevo, request: Request, correo: Correo):
    with request.app.state.motor_sistema.begin() as con:
        pedido_id = con.execute(base.pedidos.insert().values(
            dueno=correo, nombre=datos.nombre, cliente=datos.cliente, entrega=datos.entrega,
            nota=datos.nota, estado="abierto", creado=ahora_bogota(),
        )).inserted_primary_key[0]
        for i, m in enumerate(datos.modelos):
            _insertar_modelo(con, pedido_id, m, i, correo)
        return _detalle(con, pedido_id, correo)


@router.get("/api/pedidos/{pedido_id}")
def ver_pedido(pedido_id: IdRuta, request: Request, correo: Correo):
    with request.app.state.motor_sistema.connect() as con:
        return _detalle(con, pedido_id, correo)


@router.patch("/api/pedidos/{pedido_id}")
def editar_pedido(pedido_id: IdRuta, datos: PedidoCambios, request: Request, correo: Correo):
    # exclude_unset: distingue "no lo mandaron" de "mandaron null para borrarlo".
    cambios = datos.model_dump(exclude_unset=True)
    with request.app.state.motor_sistema.begin() as con:
        actual = _pedido_o_404(con, pedido_id, correo)
        if cambios.get("estado") == "terminado":
            # Si ya estaba terminado se conserva la fecha original.
            cambios["terminado_en"] = actual.terminado_en or ahora_bogota()
        elif cambios.get("estado") == "abierto":
            cambios["terminado_en"] = None
        if cambios:
            con.execute(base.pedidos.update().where(base.pedidos.c.id == pedido_id).values(**cambios))
        return _detalle(con, pedido_id, correo)


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

@router.post("/api/pedidos/{pedido_id}/modelos", status_code=201)
def agregar_modelo(pedido_id: IdRuta, datos: ModeloNuevo, request: Request, correo: Correo):
    with request.app.state.motor_sistema.begin() as con:
        _pedido_o_404(con, pedido_id, correo)
        cuantos, ultimo = con.execute(
            select(func.count(), func.coalesce(func.max(base.modelos.c.orden), -1))
            .where(base.modelos.c.pedido_id == pedido_id)
        ).one()
        if cuantos >= MAX_MODELOS:
            raise HTTPException(status_code=409, detail=f"Un pedido admite hasta {MAX_MODELOS} modelos")
        modelo_id = _insertar_modelo(con, pedido_id, datos, ultimo + 1, correo)
        return _modelo_con_hechas(con, modelo_id, correo)


@router.patch("/api/modelos/{modelo_id}")
def editar_modelo(modelo_id: IdRuta, datos: ModeloCambios, request: Request, correo: Correo):
    cambios = datos.model_dump(exclude_unset=True)
    with request.app.state.motor_sistema.begin() as con:
        _modelo_o_404(con, modelo_id, correo)
        if cambios:
            con.execute(base.modelos.update().where(base.modelos.c.id == modelo_id).values(**cambios))
        if "meta" in cambios:
            # Del stock: la venta sigue a la meta (un modelo nuevo no tiene venta: no cambia nada).
            con.execute(base.movimientos.update().where(base.movimientos.c.modelo_id == modelo_id)
                        .values(cantidad=cambios["meta"]))
        return _modelo_con_hechas(con, modelo_id, correo)


@router.delete("/api/modelos/{modelo_id}", status_code=204)
def borrar_modelo(modelo_id: IdRuta, request: Request, correo: Correo):
    with request.app.state.motor_sistema.begin() as con:
        _modelo_o_404(con, modelo_id, correo)
        # Borrar un modelo con tandas haria desaparecer piezas ya impresas del
        # conteo; primero hay que borrar (a proposito) esas tandas.
        tiene = con.execute(
            select(base.tandas.c.id).where(base.tandas.c.modelo_id == modelo_id).limit(1)).first()
        if tiene:
            raise HTTPException(status_code=409, detail="El modelo ya tiene tandas; borralas primero")
        # Del stock: borrar su venta devuelve esas piezas al stock del producto.
        con.execute(base.movimientos.delete().where(base.movimientos.c.modelo_id == modelo_id))
        con.execute(base.modelos.delete().where(base.modelos.c.id == modelo_id))
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Tandas
# ---------------------------------------------------------------------------

@router.get("/api/pedidos/{pedido_id}/tandas")
def listar_tandas(pedido_id: IdRuta, request: Request, correo: Correo,
                  modelo_id: Annotated[int | None, Field(ge=1, le=MAX_ID)] = None):
    with request.app.state.motor_sistema.connect() as con:
        _pedido_o_404(con, pedido_id, correo)
        consulta = _consulta_tandas(correo).where(base.modelos.c.pedido_id == pedido_id)
        if modelo_id is not None:
            consulta = consulta.where(base.tandas.c.modelo_id == modelo_id)
        filas = con.execute(
            consulta.order_by(base.tandas.c.cuando.desc(), base.tandas.c.id.desc())).all()
    return [_tanda_json(t) for t in filas]


@router.post("/api/tandas", status_code=201)
def crear_tanda(datos: TandaNueva, request: Request, response: Response, correo: Correo):
    motor = request.app.state.motor_sistema
    try:
        with motor.begin() as con:
            # Lo primero, antes de mirar parecidos: un reintento (timeout, cola
            # sin senal que se vacia dos veces) tiene que recibir la tanda que ya
            # quedo, jamas un 409 contra si misma.
            existente = _buscar_por_id_cliente(con, datos.id_cliente, correo)
            if existente:
                response.status_code = 200
                return _tanda_json(existente)

            if _modelo_o_404(con, datos.modelo_id, correo).opcion_id is not None:
                raise HTTPException(status_code=409,
                                    detail="Este modelo sale del stock: anota las tandas en Productos")
            cuando = datos.cuando or ahora_bogota()

            if not datos.forzar:
                # La ventana se acota en SQL para no traer todas las tandas de esa
                # cantidad; la mas reciente dentro de ella es la que Juan recuerda
                # haber anotado. es_parecida confirma con la misma regla de siempre.
                candidata = con.execute(
                    select(base.tandas.c.id, base.tandas.c.cantidad, base.tandas.c.cuando)
                    .where(base.tandas.c.modelo_id == datos.modelo_id,
                           base.tandas.c.cantidad == datos.cantidad,
                           base.tandas.c.cuando.between(
                               cuando - calculos.VENTANA_PARECIDA, cuando + calculos.VENTANA_PARECIDA))
                    .order_by(base.tandas.c.cuando.desc(), base.tandas.c.id.desc())
                    .limit(1)
                ).first()
                parecida = candidata if candidata and calculos.es_parecida(
                    datos.cantidad, cuando, candidata.cantidad, candidata.cuando) else None
                if parecida:
                    return JSONResponse(status_code=409, content={"parecida": {
                        "id": parecida.id, "cantidad": parecida.cantidad,
                        "cuando": _hora(parecida.cuando),
                        "hace_minutos": int(abs(cuando - parecida.cuando).total_seconds() // 60),
                    }})

            tanda_id = con.execute(base.tandas.insert().values(
                modelo_id=datos.modelo_id, cantidad=datos.cantidad, cuando=cuando,
                id_cliente=datos.id_cliente, creada=ahora_bogota(),
            )).inserted_primary_key[0]
            return _tanda_json(_tanda_o_404(con, tanda_id, correo))
    except IntegrityError:
        # Dos envios de la misma tanda a la vez: los dos vieron "no existe" y el
        # UNIQUE de id_cliente dejo pasar solo uno. Al otro se le da la ganadora.
        with motor.connect() as con:
            existente = _buscar_por_id_cliente(con, datos.id_cliente, correo)
        if existente is None:
            raise HTTPException(status_code=404, detail="No existe ese modelo")
        response.status_code = 200
        return _tanda_json(existente)


@router.patch("/api/tandas/{tanda_id}")
def editar_tanda(tanda_id: IdRuta, datos: TandaCambios, request: Request, correo: Correo):
    cambios = datos.model_dump(exclude_unset=True)
    with request.app.state.motor_sistema.begin() as con:
        _tanda_o_404(con, tanda_id, correo)
        if cambios:
            con.execute(base.tandas.update().where(base.tandas.c.id == tanda_id).values(**cambios))
        return _tanda_json(_tanda_o_404(con, tanda_id, correo))


@router.delete("/api/tandas/{tanda_id}", status_code=204)
def borrar_tanda(tanda_id: IdRuta, request: Request, correo: Correo):
    with request.app.state.motor_sistema.begin() as con:
        _tanda_o_404(con, tanda_id, correo)
        con.execute(base.tandas.delete().where(base.tandas.c.id == tanda_id))
    return Response(status_code=204)
