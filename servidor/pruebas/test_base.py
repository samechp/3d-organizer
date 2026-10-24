from sqlalchemy import inspect

from servidor.app import base


def test_health_responde(cliente):
    respuesta = cliente.get("/health")
    assert respuesta.status_code == 200
    assert respuesta.json() == {"ok": True}


def test_crear_tablas_dos_veces_no_falla(motores):
    motor_sistema, _ = motores
    # 'motores' ya las creo una vez; la segunda no debe fallar ni duplicar nada.
    base.crear_tablas(motor_sistema)
    assert set(inspect(motor_sistema).get_table_names()) == {
        "sesiones", "intentos", "usuarios", "pedidos", "modelos", "tandas", "perfiles", "filamentos",
    }


def test_estado_del_pedido_nace_abierto(motores):
    motor_sistema, _ = motores
    with motor_sistema.begin() as con:
        con.execute(base.pedidos.insert().values(nombre="Lote de prueba", dueno="juan@ejemplo.com"))
        fila = con.execute(base.pedidos.select()).one()
    assert fila.estado == "abierto"
    assert fila.creado is not None


def test_id_cliente_de_la_tanda_es_unico(motores):
    # Es la defensa contra el envio doble de una tanda (reintento tras timeout).
    import pytest
    from sqlalchemy.exc import IntegrityError

    motor_sistema, _ = motores
    with motor_sistema.begin() as con:
        pedido = con.execute(base.pedidos.insert().values(nombre="P", dueno="juan@ejemplo.com")).inserted_primary_key[0]
        modelo = con.execute(
            base.modelos.insert().values(pedido_id=pedido, nombre="M", meta=10, orden=0)
        ).inserted_primary_key[0]
        datos = dict(modelo_id=modelo, cantidad=5, id_cliente="a" * 36)
        con.execute(base.tandas.insert().values(**datos))
    with pytest.raises(IntegrityError):
        with motor_sistema.begin() as con:
            con.execute(base.tandas.insert().values(**datos))


def test_importar_principal_sin_variables_no_falla(monkeypatch):
    # gunicorn carga 'servidor.app.principal:app', pero las pruebas importan el
    # modulo sin entorno: crear la app no puede pasar en el import.
    monkeypatch.delenv("SISTEMA_DB_URL", raising=False)
    import importlib
    from servidor.app import principal
    importlib.reload(principal)
    assert callable(principal.crear_app)


def test_intentos_tiene_indice_por_ip_y_momento(motores):
    # El limite de intentos consulta por ip + momento en cada login.
    motor_sistema, _ = motores
    indices = inspect(motor_sistema).get_indexes("intentos")
    assert any(i["column_names"] == ["ip", "momento"] for i in indices)
