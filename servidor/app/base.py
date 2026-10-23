"""
base.py - Motores y tablas de 3D Organizer.

Dos bases, a proposito:
  sistema   -> la base propia de este servicio (pedidos, sesiones, perfiles...).
               Aqui se lee y se escribe.
  usuarios  -> la tabla printoverse.usuarios de la tienda, solo para validar la
               clave. Su usuario MySQL tiene unicamente SELECT, asi que aunque
               este servicio tuviera un fallo no puede tocar las cuentas de
               PrintoVerse.

Las tablas usan solo tipos que existen igual en MySQL y en SQLite: las
pruebas corren sobre SQLite en memoria y el servidor sobre MySQL.
"""

import os

from sqlalchemy import (
    CHAR, Boolean, CheckConstraint, Column, Date, DateTime, ForeignKey,
    Index, Integer, MetaData, Numeric, String, Table, Text, create_engine, func, text,
)


def _motor(variable: str):
    """Crea un motor leyendo la URL de una variable de entorno.

    Se lee al llamar y no al importar: asi importar el modulo (pruebas,
    herramientas) no exige tener el .env puesto.
    """
    url = os.environ.get(variable)
    if not url:
        raise RuntimeError(f"Falta la variable de entorno {variable}")
    # pre_ping: MySQL cierra las conexiones ociosas (wait_timeout) y sin esto la
    # primera peticion de la manana moriria con "server has gone away".
    # recycle: lo mismo, pero renovando antes de que el servidor las corte.
    return create_engine(url, pool_pre_ping=True, pool_recycle=1800)


def motor_sistema():
    return _motor("SISTEMA_DB_URL")


def motor_usuarios():
    return _motor("PRINTO_USUARIOS_URL")


metadata = MetaData()

# Solo guardamos el hash del token: si alguien lee la tabla no puede
# usar las sesiones.
sesiones = Table(
    "sesiones", metadata,
    Column("token_hash", CHAR(64), primary_key=True),
    Column("correo", String(120), nullable=False),
    # Sin server_default: now() de MySQL va en la hora del servidor, y acceso.py
    # compara todo en UTC. Cada insert pasa su valor UTC explicito.
    Column("creada", DateTime, nullable=False),
    Column("expira", DateTime, nullable=False),
)

# Un renglon por intento fallido de entrar; sirve para el limite de 5 en 15 min.
intentos = Table(
    "intentos", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("ip", String(45), nullable=False),  # 45 = IPv6 en texto, el caso mas largo
    # Sin server_default, por lo mismo que sesiones.creada: el momento lo pone
    # acceso.py en UTC.
    Column("momento", DateTime, nullable=False),
    # Cada login cuenta los fallos de una IP en la ultima ventana: sin este
    # indice seria recorrer toda la tabla en cada intento.
    Index("ix_intentos_ip_momento", "ip", "momento"),
)

# Vista de solo lectura de printoverse.usuarios, con las columnas que se usan.
# Va en otro MetaData a proposito: asi crear_tablas() nunca intenta crearla en
# la base de la tienda (ni podria: ese usuario MySQL solo tiene SELECT).
usuarios_tienda = Table(
    "usuarios", MetaData(),
    Column("correo", String(120), primary_key=True),
    Column("clave_hash", String(255)),
    Column("activo", Integer),
    Column("debe_cambiar", Integer),
)

pedidos = Table(
    "pedidos", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("nombre", String(120), nullable=False),
    Column("cliente", String(120)),
    Column("entrega", Date),
    Column("nota", Text),
    # Sin ENUM nativo: es una cadena que sirve igual en SQLite; el CHECK
    # evita que se cuele otro valor por una ruta mal escrita.
    Column("estado", String(12), nullable=False, server_default="abierto"),
    Column("creado", DateTime, nullable=False, server_default=func.now()),
    Column("terminado_en", DateTime),
    CheckConstraint("estado IN ('abierto', 'terminado')", name="ck_pedidos_estado"),
)

modelos = Table(
    "modelos", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("pedido_id", Integer, ForeignKey("pedidos.id"), nullable=False),
    Column("nombre", String(80), nullable=False),
    Column("meta", Integer, nullable=False),
    Column("foto", String(80)),
    Column("orden", Integer, nullable=False, server_default="0"),
)

tandas = Table(
    "tandas", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("modelo_id", Integer, ForeignKey("modelos.id"), nullable=False),
    Column("cantidad", Integer, nullable=False),
    Column("cuando", DateTime, nullable=False, server_default=func.now()),
    # La app genera este UUID al anotar la tanda. Si el envio se repite (timeout,
    # cola que se vacia dos veces) el UNIQUE hace que la segunda no cuente.
    Column("id_cliente", CHAR(36), nullable=False, unique=True),
    Column("creada", DateTime, nullable=False, server_default=func.now()),
)

perfiles = Table(
    "perfiles", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("nombre", String(80), nullable=False, unique=True),
    Column("precio_kwh", Numeric(14, 2), nullable=False),
    Column("consumo_watts", Numeric(14, 2), nullable=False),
    Column("vida_maquina_h", Numeric(14, 2), nullable=False),
    Column("precio_repuestos", Numeric(14, 2), nullable=False),
    Column("margen_error", Numeric(14, 2), nullable=False),
    Column("precio_dolar", Numeric(14, 2)),
    Column("activo", Boolean, nullable=False, server_default="1"),
)

filamentos = Table(
    "filamentos", metadata,
    Column("id", Integer, primary_key=True, autoincrement=True),
    Column("marca", String(60), nullable=False),
    Column("tipo", String(30), nullable=False),
    Column("color", String(40), nullable=False),
    Column("hex", String(7)),
    Column("precio_kg", Numeric(14, 2), nullable=False),
    Column("moneda", String(3), nullable=False),
)


def crear_tablas(motor):
    """Crea lo que falte. Se puede llamar en cada arranque: no toca lo existente."""
    metadata.create_all(motor)


def comprobar(motor):
    """SELECT 1: confirma que la base contesta (lo usa /health)."""
    with motor.connect() as con:
        con.execute(text("SELECT 1"))
