"""
conftest.py - Piezas compartidas de las pruebas del servidor.

Las pruebas no tocan MySQL: usan dos SQLite en memoria que imitan las dos
bases reales (la propia del sistema y la de usuarios de PrintoVerse).
"""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Column, Integer, MetaData, String, Table, create_engine
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
