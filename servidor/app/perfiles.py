"""
perfiles.py - Perfiles de costos y filamentos.

Un perfil es el juego de costos de una impresora (luz, desgaste, repuestos,
margen) que usa la calculadora; los filamentos son los precios por kilo. La app
los baja y los guarda para calcular sin senal.

Siempre hay un solo perfil activo: es el que la app usa por defecto. Esa regla
se cuida aqui, en la misma transaccion que cambia los datos, para que nunca
queden dos activos ni ninguno.
"""

import re
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import AfterValidator, BaseModel, Field, StringConstraints, field_validator
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from . import base
from .acceso import usuario_actual
from .pedidos import IdRuta

# Todas las rutas piden sesion, igual que en pedidos.py.
router = APIRouter(dependencies=[Depends(usuario_actual)])

# Numeric(14, 2) guarda hasta 12 digitos enteros; mas que eso reventaria la
# consulta (500) en vez de dar un 422.
MAX_DINERO = 999_999_999_999
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")


# ---------------------------------------------------------------------------
# Validacion de lo que llega
# ---------------------------------------------------------------------------

def _a_centavos(valor: float) -> float:
    # La base guarda 2 decimales; redondear aqui hace que lo que se devuelve
    # sea igual en SQLite (pruebas) y en MySQL.
    return round(valor, 2)


# strict: que 800 sea un numero y no "800" ni true. Los textos con numeros los
# convierte quien llama (el importador), no esta API.
Dinero = Annotated[float, Field(strict=True, ge=0, le=MAX_DINERO, allow_inf_nan=False),
                   AfterValidator(_a_centavos)]
# vida_maquina_h es el divisor del desgaste por hora: con 0 la formula se rompe.
Horas = Annotated[float, Field(strict=True, gt=0, le=MAX_DINERO, allow_inf_nan=False),
                  AfterValidator(_a_centavos)]
# Porcentaje sobre el costo; 1000 % ya es un error de dedo seguro.
Margen = Annotated[float, Field(strict=True, ge=0, le=1000, allow_inf_nan=False),
                   AfterValidator(_a_centavos)]


def _texto(maximo: int):
    return Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=maximo)]


# Anchos de las columnas de base.py: un texto mas largo no cabria.
NombrePerfil = _texto(80)
Marca = _texto(60)
Tipo = _texto(30)
Color = _texto(40)
ColorHex = Annotated[str, StringConstraints(pattern=HEX.pattern)]


class PerfilNuevo(BaseModel):
    nombre: NombrePerfil
    precio_kwh: Dinero
    consumo_watts: Dinero
    vida_maquina_h: Horas
    precio_repuestos: Dinero
    margen_error: Margen
    precio_dolar: Dinero | None = None
    activo: bool = False


class PerfilCambios(BaseModel):
    # Lo que no se manda no se toca; solo precio_dolar admite null (borrarlo).
    nombre: NombrePerfil | None = None
    precio_kwh: Dinero | None = None
    consumo_watts: Dinero | None = None
    vida_maquina_h: Horas | None = None
    precio_repuestos: Dinero | None = None
    margen_error: Margen | None = None
    precio_dolar: Dinero | None = None
    activo: bool | None = None

    @field_validator("nombre", "precio_kwh", "consumo_watts", "vida_maquina_h",
                     "precio_repuestos", "margen_error", "activo")
    @classmethod
    def _no_nulo(cls, v):
        if v is None:
            raise ValueError("No puede ser null")
        return v


class FilamentoNuevo(BaseModel):
    marca: Marca
    tipo: Tipo
    color: Color
    hex: ColorHex | None = None
    precio_kg: Dinero
    moneda: Literal["COP", "USD"]


class FilamentoCambios(BaseModel):
    marca: Marca | None = None
    tipo: Tipo | None = None
    color: Color | None = None
    hex: ColorHex | None = None
    precio_kg: Dinero | None = None
    moneda: Literal["COP", "USD"] | None = None

    @field_validator("marca", "tipo", "color", "precio_kg", "moneda")
    @classmethod
    def _no_nulo(cls, v):
        if v is None:
            raise ValueError("No puede ser null")
        return v


# ---------------------------------------------------------------------------
# Respuestas
# ---------------------------------------------------------------------------

def _num(valor) -> float | None:
    # float(): MySQL devuelve Decimal, que el JSON mostraria como texto.
    return None if valor is None else float(valor)


def _perfil_json(f) -> dict:
    return {
        "id": f.id, "nombre": f.nombre, "precio_kwh": _num(f.precio_kwh),
        "consumo_watts": _num(f.consumo_watts), "vida_maquina_h": _num(f.vida_maquina_h),
        "precio_repuestos": _num(f.precio_repuestos), "margen_error": _num(f.margen_error),
        "precio_dolar": _num(f.precio_dolar), "activo": bool(f.activo),
    }


def _filamento_json(f) -> dict:
    return {
        "id": f.id, "marca": f.marca, "tipo": f.tipo, "color": f.color, "hex": f.hex,
        "precio_kg": _num(f.precio_kg), "moneda": f.moneda,
    }


def _perfil_o_404(con, perfil_id: int):
    fila = con.execute(select(base.perfiles).where(base.perfiles.c.id == perfil_id)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese perfil")
    return fila


def _filamento_o_404(con, filamento_id: int):
    fila = con.execute(select(base.filamentos).where(base.filamentos.c.id == filamento_id)).first()
    if fila is None:
        raise HTTPException(status_code=404, detail="No existe ese filamento")
    return fila


def _nombre_repetido():
    return HTTPException(status_code=409, detail="Ya hay un perfil con ese nombre")


def _apagar_los_demas(con, perfil_id: int):
    con.execute(base.perfiles.update()
                .where(base.perfiles.c.id != perfil_id).values(activo=False))


# ---------------------------------------------------------------------------
# Perfiles
# ---------------------------------------------------------------------------

@router.get("/api/perfiles")
def listar_perfiles(request: Request):
    with request.app.state.motor_sistema.connect() as con:
        filas = con.execute(select(base.perfiles).order_by(base.perfiles.c.id)).all()
    return [_perfil_json(f) for f in filas]


@router.post("/api/perfiles", status_code=201)
def crear_perfil(datos: PerfilNuevo, request: Request):
    valores = datos.model_dump()
    try:
        with request.app.state.motor_sistema.begin() as con:
            if con.execute(select(base.perfiles.c.id)
                           .where(base.perfiles.c.nombre == datos.nombre)).first():
                raise _nombre_repetido()
            hay_otros = con.execute(select(func.count()).select_from(base.perfiles)).scalar() > 0
            # El primero siempre queda activo: sin perfil activo la app no sabe
            # con que costos calcular.
            valores["activo"] = datos.activo or not hay_otros
            perfil_id = con.execute(base.perfiles.insert().values(**valores)).inserted_primary_key[0]
            if valores["activo"]:
                _apagar_los_demas(con, perfil_id)
            return _perfil_json(_perfil_o_404(con, perfil_id))
    except IntegrityError:
        # Dos altas a la vez con el mismo nombre: las dos vieron "no existe" y el
        # UNIQUE dejo pasar solo una.
        raise _nombre_repetido()


@router.patch("/api/perfiles/{perfil_id}")
def editar_perfil(perfil_id: IdRuta, datos: PerfilCambios, request: Request):
    cambios = datos.model_dump(exclude_unset=True)
    try:
        with request.app.state.motor_sistema.begin() as con:
            actual = _perfil_o_404(con, perfil_id)
            if "nombre" in cambios and con.execute(
                    select(base.perfiles.c.id).where(base.perfiles.c.nombre == cambios["nombre"],
                                                     base.perfiles.c.id != perfil_id)).first():
                raise _nombre_repetido()
            if cambios.get("activo") is False and actual.activo:
                # Apagar el unico activo dejaria la app sin perfil; para cambiar
                # de perfil se activa el otro.
                raise HTTPException(status_code=409, detail="Siempre debe haber un perfil activo; activa otro")
            if cambios:
                con.execute(base.perfiles.update().where(base.perfiles.c.id == perfil_id).values(**cambios))
            if cambios.get("activo"):
                _apagar_los_demas(con, perfil_id)
            return _perfil_json(_perfil_o_404(con, perfil_id))
    except IntegrityError:
        raise _nombre_repetido()


@router.delete("/api/perfiles/{perfil_id}", status_code=204)
def borrar_perfil(perfil_id: IdRuta, request: Request):
    with request.app.state.motor_sistema.begin() as con:
        perfil = _perfil_o_404(con, perfil_id)
        if con.execute(select(func.count()).select_from(base.perfiles)).scalar() <= 1:
            raise HTTPException(status_code=409, detail="No se puede borrar el último perfil")
        con.execute(base.perfiles.delete().where(base.perfiles.c.id == perfil_id))
        if perfil.activo:
            # Pasa la marca al mas antiguo que queda, para no dejar la app sin activo.
            heredero = con.execute(select(func.min(base.perfiles.c.id))).scalar()
            con.execute(base.perfiles.update().where(base.perfiles.c.id == heredero).values(activo=True))
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Filamentos
# ---------------------------------------------------------------------------

@router.get("/api/filamentos")
def listar_filamentos(request: Request):
    with request.app.state.motor_sistema.connect() as con:
        filas = con.execute(select(base.filamentos).order_by(base.filamentos.c.id)).all()
    return [_filamento_json(f) for f in filas]


@router.post("/api/filamentos", status_code=201)
def crear_filamento(datos: FilamentoNuevo, request: Request):
    with request.app.state.motor_sistema.begin() as con:
        filamento_id = con.execute(
            base.filamentos.insert().values(**datos.model_dump())).inserted_primary_key[0]
        return _filamento_json(_filamento_o_404(con, filamento_id))


@router.patch("/api/filamentos/{filamento_id}")
def editar_filamento(filamento_id: IdRuta, datos: FilamentoCambios, request: Request):
    cambios = datos.model_dump(exclude_unset=True)
    with request.app.state.motor_sistema.begin() as con:
        _filamento_o_404(con, filamento_id)
        if cambios:
            con.execute(base.filamentos.update()
                        .where(base.filamentos.c.id == filamento_id).values(**cambios))
        return _filamento_json(_filamento_o_404(con, filamento_id))


@router.delete("/api/filamentos/{filamento_id}", status_code=204)
def borrar_filamento(filamento_id: IdRuta, request: Request):
    with request.app.state.motor_sistema.begin() as con:
        _filamento_o_404(con, filamento_id)
        con.execute(base.filamentos.delete().where(base.filamentos.c.id == filamento_id))
    return Response(status_code=204)
