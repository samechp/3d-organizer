"""
conftest.py - Piezas compartidas de las pruebas del servidor.

Las pruebas no tocan MySQL: usan dos SQLite en memoria que imitan las dos
bases reales (la propia del sistema y la de usuarios de PrintoVerse).
"""

import hashlib
import secrets

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Column, Integer, MetaData, String, Table, create_engine, text
from sqlalchemy.pool import StaticPool

from servidor.app import base
from servidor.app.principal import crear_app


def _motor_en_memoria():
    # StaticPool + check_same_thread=False: sin esto cada conexion (y cada hilo
    # del TestClient) vería su propia base :memory: vacia.
    return create_engine(
        "sqlite://",
        poolclass=StaticPool,
        connect_args={"check_same_thread": False},
    )


@pytest.fixture
def motores(monkeypatch):
    """(motor_sistema, motor_usuarios) ya con sus tablas.

    El motor de usuarios lleva una copia falsa de printoverse.usuarios, con solo
    las columnas que el sistema lee. Se expone aparte del cliente para que las
    pruebas de acceso puedan insertar cuentas de prueba.
    """
    monkeypatch.setenv("SISTEMA_CORREO_PERMITIDO", "juan@ejemplo.com")

    motor_sistema = _motor_en_memoria()
    motor_usuarios = _motor_en_memoria()

    base.crear_tablas(motor_sistema)
    usuarios = Table(
        "usuarios",
        MetaData(),
        Column("correo", String(120), primary_key=True),
        Column("clave_hash", String(255)),
        Column("activo", Integer),
        Column("debe_cambiar", Integer),
    )
    usuarios.metadata.create_all(motor_usuarios)
    return motor_sistema, motor_usuarios


@pytest.fixture
def cliente(motores):
    motor_sistema, motor_usuarios = motores
    return TestClient(crear_app(motor_sistema, motor_usuarios))


# ---------------------------------------------------------------------------
# Ayudas de acceso (solo para pruebas)
# ---------------------------------------------------------------------------
CORREO_JUAN = "juan@ejemplo.com"
CLAVE_JUAN = "clave-de-prueba-1"


def cifrar(clave: str, n: int = 1 << 14) -> str:
    """Huella en el formato de PrintoVerse, pero con n=2^14.

    Con el n de produccion (2^15) cada prueba tardaria ~100 ms de mas;
    verificar_clave lee el n que trae la huella, asi que sirve igual.
    """
    sal = secrets.token_bytes(16)
    h = hashlib.scrypt(clave.encode("utf-8"), salt=sal, n=n, r=8, p=1,
                       dklen=32, maxmem=128 * n * 8 * 2)
    return f"scrypt${n}$8$1${sal.hex()}${h.hex()}"


def poner_usuario(motor_usuarios, correo, clave, activo=1, debe_cambiar=0):
    """Inserta una cuenta en la copia falsa de printoverse.usuarios."""
    with motor_usuarios.begin() as con:
        con.execute(
            text("INSERT INTO usuarios (correo, clave_hash, activo, debe_cambiar) "
                 "VALUES (:c, :h, :a, :d)"),
            {"c": correo, "h": cifrar(clave), "a": activo, "d": debe_cambiar},
        )


@pytest.fixture
def cliente_con_sesion(cliente, motores):
    """Cliente ya dentro como Juan, mandando 'Authorization: Bearer <token>'.

    Es lo que usan las pruebas de pedidos, modelos, etc. Entra por la ruta
    real (POST /api/acceso) para que la prueba ejercite el mismo camino que
    la app del iPhone.
    """
    _, motor_usuarios = motores
    poner_usuario(motor_usuarios, CORREO_JUAN, CLAVE_JUAN)
    respuesta = cliente.post("/api/acceso", json={"correo": CORREO_JUAN, "clave": CLAVE_JUAN})
    assert respuesta.status_code == 200
    # La cookie se descarta: asi toda peticion de la prueba va por Bearer y
    # no hace falta mandar X-Sistema en los POST.
    cliente.cookies.clear()
    cliente.headers["Authorization"] = f"Bearer {respuesta.json()['token']}"
    return cliente
