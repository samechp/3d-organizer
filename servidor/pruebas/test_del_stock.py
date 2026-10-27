"""Modelos del stock: un modelo de pedido que sale de una opcion de Productos.

Crearlo anota una venta en esa opcion; su meta y la venta van juntas (cambiar
una cambia la otra, borrar el modelo borra la venta) y el pedido lo cuenta
como hecho.
"""

import uuid
from datetime import datetime

import pytest

from servidor.app import pedidos

AHORA = datetime(2026, 10, 24, 15, 0, 0)


@pytest.fixture(autouse=True)
def hora_fija(monkeypatch):
    monkeypatch.setattr(pedidos, "ahora_bogota", lambda: AHORA)


@pytest.fixture
def producto(cliente_con_sesion):
    r = cliente_con_sesion.post("/api/productos", json={"nombre": "Soporte", "opciones": [
        {"nombre": "Negro", "hechos": 10}, {"nombre": "Blanco"}]})
    assert r.status_code == 201, r.text
    p = r.json()
    return {"id": p["id"], "negro": p["opciones"][0]["id"], "blanco": p["opciones"][1]["id"]}


def _pedido(c, modelos, **extra):
    return c.post("/api/pedidos", json={"nombre": "Feria", "modelos": modelos}, **extra)


def _saldo(c, producto, opcion):
    return next(o["saldo"] for o in c.get(f"/api/productos/{producto['id']}").json()["opciones"]
                if o["id"] == opcion)


def test_crear_descuenta_stock_y_cuenta_como_hecho(cliente_con_sesion, producto):
    c = cliente_con_sesion
    r = _pedido(c, [{"opcion_id": producto["negro"], "meta": 4}])
    assert r.status_code == 201, r.text
    m = r.json()["modelos"][0]
    assert m["nombre"] == "Soporte · Negro" and m["opcion_id"] == producto["negro"]
    assert m["hechas"] == 4 and m["completo"] is True and m["faltan"] == 0
    assert m["del_stock"] == {"producto_id": producto["id"], "producto": "Soporte", "opcion": "Negro", "saldo": 6}
    assert r.json()["avance"]["porcentaje"] == 100
    assert _saldo(c, producto, producto["negro"]) == 6
    # En Productos es una venta mas, con el pedido al lado.
    venta = c.get(f"/api/productos/{producto['id']}").json()["movimientos"][0]
    assert (venta["tipo"], venta["cantidad"], venta["modelo_id"], venta["pedido"]) == ("venta", 4, m["id"], "Feria")
    assert venta["pedido_id"] == r.json()["id"]


def test_sin_stock_suficiente_queda_negativo(cliente_con_sesion, producto):
    c = cliente_con_sesion
    m = _pedido(c, [{"opcion_id": producto["blanco"], "meta": 3, "nombre": "Blancos"}]).json()["modelos"][0]
    assert m["nombre"] == "Blancos" and m["completo"] is True
    assert m["del_stock"]["saldo"] == -3
    assert _saldo(c, producto, producto["blanco"]) == -3


def test_cambiar_meta_ajusta_la_venta_y_borrar_la_devuelve(cliente_con_sesion, producto):
    c = cliente_con_sesion
    m = _pedido(c, [{"opcion_id": producto["negro"], "meta": 4}]).json()["modelos"][0]
    r = c.patch(f"/api/modelos/{m['id']}", json={"meta": 7})
    assert r.status_code == 200 and r.json()["del_stock"]["saldo"] == 3 and r.json()["hechas"] == 7
    assert _saldo(c, producto, producto["negro"]) == 3
    # La opcion no se cambia por PATCH.
    assert c.patch(f"/api/modelos/{m['id']}", json={"opcion_id": producto["blanco"]}).status_code == 422
    assert c.delete(f"/api/modelos/{m['id']}").status_code == 204
    assert _saldo(c, producto, producto["negro"]) == 10
    assert c.get(f"/api/productos/{producto['id']}").json()["movimientos"][0]["tipo"] == "tanda"


def test_agregar_modelo_del_stock_a_un_pedido(cliente_con_sesion, producto):
    c = cliente_con_sesion
    p = _pedido(c, [{"nombre": "Dragon", "meta": 2}]).json()
    r = c.post(f"/api/pedidos/{p['id']}/modelos", json={"opcion_id": producto["negro"], "meta": 1})
    assert r.status_code == 201 and r.json()["completo"] is True
    assert _saldo(c, producto, producto["negro"]) == 9
    assert c.post(f"/api/pedidos/{p['id']}/modelos", json={"meta": 1}).status_code == 422


def test_tanda_y_cambios_en_productos_se_rechazan(cliente_con_sesion, producto):
    c = cliente_con_sesion
    m = _pedido(c, [{"opcion_id": producto["negro"], "meta": 4}]).json()["modelos"][0]
    r = c.post("/api/tandas", json={"modelo_id": m["id"], "cantidad": 1, "id_cliente": str(uuid.uuid4())})
    assert r.status_code == 409 and "Productos" in r.json()["detail"]
    venta = c.get(f"/api/productos/{producto['id']}").json()["movimientos"][0]
    assert c.patch(f"/api/movimientos/{venta['id']}", json={"cantidad": 1}).status_code == 409
    assert c.delete(f"/api/movimientos/{venta['id']}").status_code == 409
    assert c.delete(f"/api/opciones/{producto['negro']}").status_code == 409
    assert _saldo(c, producto, producto["negro"]) == 6


def test_pedido_mixto(cliente_con_sesion, producto):
    c = cliente_con_sesion
    p = _pedido(c, [{"nombre": "Dragon", "meta": 6}, {"opcion_id": producto["negro"], "meta": 4}]).json()
    assert [m["del_stock"] is None for m in p["modelos"]] == [True, False]
    assert p["avance"] == {"hechas_total": 4, "meta_total": 10, "contadas": 4, "faltan": 6, "porcentaje": 40}
    lista = c.get("/api/pedidos").json()
    assert lista[0]["avance"]["contadas"] == 4


def test_opcion_ajena(cliente_con_sesion, producto, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    # El amigo no puede descontar del stock de Juan: como si la opcion no existiera.
    assert _pedido(c, [{"opcion_id": producto["negro"], "meta": 1}], headers=a).status_code == 404
    assert c.get("/api/pedidos", headers=a).json() == []
    otro = _pedido(c, [{"nombre": "X", "meta": 1}], headers=a).json()
    assert c.post(f"/api/pedidos/{otro['id']}/modelos", headers=a,
                  json={"opcion_id": producto["negro"], "meta": 1}).status_code == 404
    assert _saldo(c, producto, producto["negro"]) == 10
    # Y no ve ni toca lo enlazado de Juan.
    m = _pedido(c, [{"opcion_id": producto["negro"], "meta": 2}]).json()["modelos"][0]
    venta = c.get(f"/api/productos/{producto['id']}").json()["movimientos"][0]
    assert c.get(f"/api/productos/{producto['id']}", headers=a).status_code == 404
    assert c.patch(f"/api/modelos/{m['id']}", headers=a, json={"meta": 1}).status_code == 404
    assert c.delete(f"/api/modelos/{m['id']}", headers=a).status_code == 404
    assert c.delete(f"/api/movimientos/{venta['id']}", headers=a).status_code == 404
    assert _saldo(c, producto, producto["negro"]) == 8
