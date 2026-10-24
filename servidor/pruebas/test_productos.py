"""Productos: saldo por opcion (tandas suman, ventas restan) y aislamiento por cuenta."""

import hashlib
import uuid
from datetime import datetime

import pytest

from servidor.app import pedidos

from .test_perfiles import PNG

AHORA = datetime(2026, 10, 24, 15, 0, 0)


@pytest.fixture(autouse=True)
def hora_fija(monkeypatch):
    monkeypatch.setattr(pedidos, "ahora_bogota", lambda: AHORA)


def _producto(c, **extra):
    r = c.post("/api/productos", json={"nombre": "Soporte", "opciones": [
        {"nombre": "Negro", "hechos": 10}, {"nombre": "Blanco"}]}, **extra)
    assert r.status_code == 201, r.text
    return r.json()


def _mov(c, opcion, tipo, cantidad, **extra):
    cuerpo = {"opcion_id": opcion, "tipo": tipo, "cantidad": cantidad, "id_cliente": str(uuid.uuid4())}
    cuerpo.update(extra.pop("json", {}))
    return c.post("/api/movimientos", json=cuerpo, **extra)


def _saldos(c, producto_id):
    return {o["nombre"]: o["saldo"] for o in c.get(f"/api/productos/{producto_id}").json()["opciones"]}


def test_crear_con_hechos_deja_ese_saldo(cliente_con_sesion):
    p = _producto(cliente_con_sesion)
    assert p["nombre"] == "Soporte" and p["foto_url"] is None
    assert [(o["nombre"], o["saldo"]) for o in p["opciones"]] == [("Negro", 10), ("Blanco", 0)]
    assert p["stock"] == 10 and p["faltan"] == 0
    # Los hechos quedan como una tanda que se puede corregir.
    assert [(m["tipo"], m["cantidad"], m["opcion"]) for m in p["movimientos"]] == [("tanda", 10, "Negro")]


def test_venta_resta_tanda_suma_y_negativo_es_faltan(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro, blanco = (o["id"] for o in p["opciones"])
    assert _mov(c, negro, "venta", 3).status_code == 201
    assert _mov(c, blanco, "venta", 5).status_code == 201
    assert _mov(c, blanco, "tanda", 2).status_code == 201
    assert _saldos(c, p["id"]) == {"Negro": 7, "Blanco": -3}
    d = c.get(f"/api/productos/{p['id']}").json()
    assert d["stock"] == 7 and d["faltan"] == 3


def test_lista_con_totales_por_producto(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    otro = c.post("/api/productos", json={"nombre": "Llavero", "opciones": [{"nombre": "Rosado"}]}).json()
    _mov(c, otro["opciones"][0]["id"], "venta", 4)
    lista = {x["id"]: x for x in c.get("/api/productos").json()}
    assert set(lista) == {p["id"], otro["id"]}
    assert (lista[p["id"]]["stock"], lista[p["id"]]["faltan"]) == (10, 0)
    assert (lista[otro["id"]]["stock"], lista[otro["id"]]["faltan"]) == (0, 4)
    assert lista[otro["id"]]["opciones"] == [{"id": otro["opciones"][0]["id"], "nombre": "Rosado", "saldo": -4}]
    assert "movimientos" not in lista[p["id"]]


def test_id_cliente_repetido_no_cuenta_dos_veces(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro = p["opciones"][0]["id"]
    cuerpo = {"opcion_id": negro, "tipo": "venta", "cantidad": 2, "id_cliente": str(uuid.uuid4()).upper()}
    primera = c.post("/api/movimientos", json=cuerpo)
    otra = c.post("/api/movimientos", json=cuerpo)
    assert primera.status_code == 201 and otra.status_code == 200
    assert otra.json()["id"] == primera.json()["id"]
    assert _saldos(c, p["id"])["Negro"] == 8


def test_parecida_solo_para_tandas(cliente_con_sesion):
    c = cliente_con_sesion
    negro = _producto(c)["opciones"][0]["id"]
    # Dos ventas iguales seguidas son dos clientes: las dos cuentan.
    assert _mov(c, negro, "venta", 1).status_code == 201
    assert _mov(c, negro, "venta", 1).status_code == 201
    # Los hechos iniciales (tanda de 10 ahora mismo) ya cuentan como tanda previa.
    r = _mov(c, negro, "tanda", 10)
    assert r.status_code == 409
    assert r.json()["parecida"]["cantidad"] == 10 and r.json()["parecida"]["hace_minutos"] == 0


def test_forzar_guarda_la_tanda_parecida_con_el_mismo_id(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro = p["opciones"][0]["id"]
    id_cliente = str(uuid.uuid4())
    cuerpo = {"opcion_id": negro, "tipo": "tanda", "cantidad": 10, "id_cliente": id_cliente}
    assert c.post("/api/movimientos", json=cuerpo).status_code == 409
    r = c.post("/api/movimientos", json={**cuerpo, "forzar": True})
    assert r.status_code == 201 and r.json()["id_cliente"] == id_cliente
    assert _saldos(c, p["id"])["Negro"] == 20
    # Fuera de la ventana de 3 h ya no avisa.
    r = _mov(c, negro, "tanda", 10, json={"cuando": "2026-10-24T08:00:00-05:00"})
    assert r.status_code == 201


def test_corregir_y_borrar_movimiento_recalcula(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro = p["opciones"][0]["id"]
    venta = _mov(c, negro, "venta", 3).json()
    r = c.patch(f"/api/movimientos/{venta['id']}", json={"cantidad": 12, "cuando": "2026-10-23T10:00:00-05:00"})
    assert r.status_code == 200 and r.json()["cantidad"] == 12
    assert r.json()["cuando"] == "2026-10-23T10:00:00-05:00"
    assert _saldos(c, p["id"])["Negro"] == -2
    assert c.delete(f"/api/movimientos/{venta['id']}").status_code == 204
    assert _saldos(c, p["id"])["Negro"] == 10
    assert c.delete(f"/api/movimientos/{venta['id']}").status_code == 404


def test_listar_movimientos_por_opcion(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro, blanco = (o["id"] for o in p["opciones"])
    _mov(c, blanco, "venta", 1)
    todos = c.get(f"/api/productos/{p['id']}/movimientos").json()
    assert len(todos) == 2
    solo = c.get(f"/api/productos/{p['id']}/movimientos", params={"opcion_id": blanco}).json()
    assert [m["opcion_id"] for m in solo] == [blanco]


def test_opciones_agregar_renombrar_y_borrar(cliente_con_sesion):
    c = cliente_con_sesion
    p = _producto(c)
    negro, blanco = (o["id"] for o in p["opciones"])
    r = c.post(f"/api/productos/{p['id']}/opciones", json={"nombre": "Rojo"})
    assert r.status_code == 201 and r.json()["saldo"] == 0
    rojo = r.json()["id"]
    assert c.patch(f"/api/opciones/{rojo}", json={"nombre": "Rojo vino"}).json()["nombre"] == "Rojo vino"
    # Nombre repetido dentro del producto: 409, al crear, al agregar y al renombrar.
    assert c.patch(f"/api/opciones/{rojo}", json={"nombre": "Negro"}).status_code == 409
    assert c.post(f"/api/productos/{p['id']}/opciones", json={"nombre": "Blanco"}).status_code == 409
    assert c.post("/api/productos", json={"nombre": "X", "opciones": [
        {"nombre": "A"}, {"nombre": "A"}]}).status_code == 409
    # Con movimientos no se borra; sin ellos si.
    assert c.delete(f"/api/opciones/{negro}").status_code == 409
    assert c.delete(f"/api/opciones/{blanco}").status_code == 204
    assert [o["nombre"] for o in c.get(f"/api/productos/{p['id']}").json()["opciones"]] == ["Negro", "Rojo vino"]
    assert c.patch(f"/api/productos/{p['id']}", json={"nombre": "Soporte mic"}).json()["nombre"] == "Soporte mic"


@pytest.mark.parametrize("cantidad", [0, -1, 100_001, "5", 2.0, True])
def test_cantidad_invalida_es_422(cliente_con_sesion, cantidad):
    c = cliente_con_sesion
    negro = _producto(c)["opciones"][0]["id"]
    assert _mov(c, negro, "venta", cantidad).status_code == 422


def test_otros_datos_invalidos_son_422(cliente_con_sesion):
    c = cliente_con_sesion
    negro = _producto(c)["opciones"][0]["id"]
    assert _mov(c, negro, "regalo", 1).status_code == 422
    assert c.post("/api/productos", json={"nombre": "X", "opciones": []}).status_code == 422
    assert c.post("/api/productos", json={"nombre": "X", "opciones": [
        {"nombre": "A", "hechos": -1}]}).status_code == 422


def test_foto_del_producto(cliente_con_sesion, tmp_path, monkeypatch):
    monkeypatch.setenv("SISTEMA_FOTOS", str(tmp_path))
    c = cliente_con_sesion
    p = _producto(c)
    r = c.put(f"/api/productos/{p['id']}/foto", files={"foto": ("a.png", PNG, "image/png")})
    assert r.status_code == 200
    nombre = hashlib.sha256(PNG).hexdigest() + ".png"
    assert r.json()["foto_url"] == f"/api/fotos/{nombre}"
    assert c.get(f"/api/fotos/{nombre}").content == PNG


# ---------------------------------------------------------------------------
# Aislamiento: lo de Juan no existe para el amigo
# ---------------------------------------------------------------------------

def test_lo_ajeno_es_404(cliente_con_sesion, cabeceras_amigo, tmp_path, monkeypatch):
    monkeypatch.setenv("SISTEMA_FOTOS", str(tmp_path))
    c, a = cliente_con_sesion, cabeceras_amigo
    p = _producto(c)
    negro = p["opciones"][0]["id"]
    mov = p["movimientos"][0]["id"]
    c.put(f"/api/productos/{p['id']}/foto", files={"foto": ("a.png", PNG, "image/png")})
    foto = hashlib.sha256(PNG).hexdigest() + ".png"

    assert c.get("/api/productos", headers=a).json() == []
    for metodo, ruta, cuerpo in (
        ("GET", f"/api/productos/{p['id']}", None),
        ("PATCH", f"/api/productos/{p['id']}", {"nombre": "X"}),
        ("GET", f"/api/productos/{p['id']}/movimientos", None),
        ("POST", f"/api/productos/{p['id']}/opciones", {"nombre": "Rojo"}),
        ("PATCH", f"/api/opciones/{negro}", {"nombre": "X"}),
        ("DELETE", f"/api/opciones/{negro}", None),
        ("PATCH", f"/api/movimientos/{mov}", {"cantidad": 1}),
        ("DELETE", f"/api/movimientos/{mov}", None),
        ("POST", "/api/movimientos", {"opcion_id": negro, "tipo": "venta", "cantidad": 1,
                                       "id_cliente": str(uuid.uuid4())}),
    ):
        assert c.request(metodo, ruta, json=cuerpo, headers=a).status_code == 404, (metodo, ruta)
    assert c.put(f"/api/productos/{p['id']}/foto", headers=a,
                 files={"foto": ("a.png", PNG, "image/png")}).status_code == 404
    assert c.get(f"/api/fotos/{foto}", headers=a).status_code == 404
    # Nada cambio para Juan.
    d = c.get(f"/api/productos/{p['id']}").json()
    assert d["nombre"] == "Soporte" and d["stock"] == 10 and len(d["opciones"]) == 2


def test_id_cliente_de_otra_cuenta_da_409(cliente_con_sesion, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    negro = _producto(c)["opciones"][0]["id"]
    id_cliente = str(uuid.uuid4())
    _mov(c, negro, "venta", 1, json={"id_cliente": id_cliente})
    suya = _producto(c, headers=a)["opciones"][0]["id"]
    r = _mov(c, suya, "venta", 1, headers=a, json={"id_cliente": id_cliente})
    assert r.status_code == 409 and "id" not in r.json()


def test_crear_dos_veces_con_el_mismo_id_cliente_da_un_solo_producto(cliente_con_sesion):
    c = cliente_con_sesion
    id_cliente = str(uuid.uuid4()).upper()
    cuerpo = {"nombre": "Soporte", "opciones": [{"nombre": "Negro", "hechos": 10}], "id_cliente": id_cliente}
    primero = c.post("/api/productos", json=cuerpo)
    assert primero.status_code == 201, primero.text
    # El reintento (en minusculas o mayusculas da igual) devuelve el mismo, sin sumar stock.
    cuerpo["id_cliente"] = id_cliente.lower()
    otra = c.post("/api/productos", json=cuerpo)
    assert otra.status_code == 200 and otra.json()["id"] == primero.json()["id"]
    assert len(c.get("/api/productos").json()) == 1
    assert _saldos(c, primero.json()["id"]) == {"Negro": 10}


def test_crear_sin_id_cliente_sigue_sirviendo_dos_veces(cliente_con_sesion):
    c = cliente_con_sesion
    _producto(c)
    _producto(c)
    assert len(c.get("/api/productos").json()) == 2


def test_id_cliente_de_producto_de_otra_cuenta_da_409(cliente_con_sesion, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    id_cliente = str(uuid.uuid4())
    cuerpo = {"nombre": "Soporte", "opciones": [{"nombre": "Negro"}], "id_cliente": id_cliente}
    assert c.post("/api/productos", json=cuerpo).status_code == 201
    r = c.post("/api/productos", json=cuerpo, headers=a)
    assert r.status_code == 409 and "id" not in r.json()
    assert c.get("/api/productos", headers=a).json() == []
