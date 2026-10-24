"""Cada cuenta ve y cambia solo lo suyo.

Juan (cliente_con_sesion) crea datos y el amigo (cabeceras_amigo) intenta verlos
o tocarlos. Lo de otra cuenta tiene que comportarse como si no existiera: 404,
nunca 403, para no dejar saber que el id esta ocupado.
"""

import hashlib
import uuid

import pytest

from .test_perfiles import PERFIL, PNG

FILAMENTO = {"marca": "Colido", "tipo": "PLA", "color": "Negro", "precio_kg": 72000, "moneda": "COP"}


@pytest.fixture
def de_juan(cliente_con_sesion, tmp_path, monkeypatch):
    """Un pedido de Juan con una tanda y una foto, mas un perfil y un filamento."""
    monkeypatch.setenv("SISTEMA_FOTOS", str(tmp_path))
    c = cliente_con_sesion
    pedido = c.post("/api/pedidos", json={"nombre": "P", "modelos": [{"nombre": "M", "meta": 5}]}).json()
    modelo = pedido["modelos"][0]["id"]
    id_cliente = str(uuid.uuid4())
    tanda = c.post("/api/tandas", json={"modelo_id": modelo, "cantidad": 2, "id_cliente": id_cliente}).json()
    c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", PNG, "image/png")})
    return {
        "pedido": pedido["id"], "modelo": modelo, "tanda": tanda["id"], "id_cliente": id_cliente,
        "foto": hashlib.sha256(PNG).hexdigest() + ".png",
        "perfil": c.post("/api/perfiles", json=PERFIL).json()["id"],
        "filamento": c.post("/api/filamentos", json=FILAMENTO).json()["id"],
    }


def test_el_amigo_empieza_con_todo_vacio(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    for ruta in ("/api/pedidos", "/api/pedidos?estado=abierto", "/api/perfiles", "/api/filamentos"):
        assert c.get(ruta, headers=a).json() == [], ruta
    # Juan sigue viendo lo suyo.
    assert len(c.get("/api/pedidos").json()) == 1


def test_pedido_ajeno_es_404(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a, j = cliente_con_sesion, cabeceras_amigo, de_juan
    assert c.get(f"/api/pedidos/{j['pedido']}", headers=a).status_code == 404
    assert c.patch(f"/api/pedidos/{j['pedido']}", headers=a, json={"nombre": "X"}).status_code == 404
    assert c.post(f"/api/pedidos/{j['pedido']}/modelos", headers=a,
                  json={"nombre": "X", "meta": 1}).status_code == 404
    assert c.get(f"/api/pedidos/{j['pedido']}/tandas", headers=a).status_code == 404
    # Nada cambio para Juan.
    detalle = c.get(f"/api/pedidos/{j['pedido']}").json()
    assert detalle["nombre"] == "P" and len(detalle["modelos"]) == 1


def test_modelo_y_tanda_ajenos_son_404(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a, j = cliente_con_sesion, cabeceras_amigo, de_juan
    assert c.patch(f"/api/modelos/{j['modelo']}", headers=a, json={"meta": 9}).status_code == 404
    assert c.delete(f"/api/modelos/{j['modelo']}", headers=a).status_code == 404
    assert c.post("/api/tandas", headers=a, json={
        "modelo_id": j["modelo"], "cantidad": 3, "id_cliente": str(uuid.uuid4())}).status_code == 404
    assert c.patch(f"/api/tandas/{j['tanda']}", headers=a, json={"cantidad": 9}).status_code == 404
    assert c.delete(f"/api/tandas/{j['tanda']}", headers=a).status_code == 404
    assert c.put(f"/api/modelos/{j['modelo']}/foto", headers=a,
                 files={"foto": ("a.png", PNG, "image/png")}).status_code == 404
    modelo = c.get(f"/api/pedidos/{j['pedido']}").json()["modelos"][0]
    assert modelo["meta"] == 5 and modelo["hechas"] == 2


def test_foto_ajena_es_404(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a, j = cliente_con_sesion, cabeceras_amigo, de_juan
    assert c.get(f"/api/fotos/{j['foto']}").status_code == 200
    assert c.get(f"/api/fotos/{j['foto']}", headers=a).status_code == 404


def test_perfil_y_filamento_ajenos_son_404(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a, j = cliente_con_sesion, cabeceras_amigo, de_juan
    assert c.patch(f"/api/perfiles/{j['perfil']}", headers=a, json={"precio_kwh": 1}).status_code == 404
    assert c.delete(f"/api/perfiles/{j['perfil']}", headers=a).status_code == 404
    assert c.patch(f"/api/filamentos/{j['filamento']}", headers=a, json={"precio_kg": 1}).status_code == 404
    assert c.delete(f"/api/filamentos/{j['filamento']}", headers=a).status_code == 404
    assert c.get("/api/perfiles").json()[0]["precio_kwh"] == 800
    assert c.get("/api/filamentos").json()[0]["precio_kg"] == 72000


def test_amigo_usa_el_mismo_nombre_y_su_primer_perfil_es_activo(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    r = c.post("/api/perfiles", headers=a, json=PERFIL)
    assert r.status_code == 201 and r.json()["nombre"] == PERFIL["nombre"] and r.json()["activo"]
    # Su perfil activo no apaga el de Juan.
    assert c.get("/api/perfiles").json()[0]["activo"] is True
    # El de Juan es "el ultimo" solo para Juan: el amigo tampoco puede borrar el suyo.
    assert c.delete(f"/api/perfiles/{r.json()['id']}", headers=a).status_code == 409
    # Dentro de la misma cuenta el nombre sigue sin poder repetirse.
    assert c.post("/api/perfiles", headers=a, json=PERFIL).status_code == 409


def test_activar_otro_perfil_no_toca_los_de_otra_cuenta(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a = cliente_con_sesion, cabeceras_amigo
    c.post("/api/perfiles", headers=a, json=PERFIL)
    segundo = c.post("/api/perfiles", headers=a, json=dict(PERFIL, nombre="Otro", activo=True)).json()
    assert segundo["activo"]
    assert [p["activo"] for p in c.get("/api/perfiles", headers=a).json()] == [False, True]
    assert c.get("/api/perfiles").json()[0]["activo"] is True


def test_id_cliente_de_otra_cuenta_da_409_sin_datos(cliente_con_sesion, de_juan, cabeceras_amigo):
    c, a, j = cliente_con_sesion, cabeceras_amigo, de_juan
    modelo = c.post("/api/pedidos", headers=a,
                    json={"nombre": "Mio", "modelos": [{"nombre": "N", "meta": 3}]}).json()["modelos"][0]["id"]
    r = c.post("/api/tandas", headers=a, json={"modelo_id": modelo, "cantidad": 2, "id_cliente": j["id_cliente"]})
    assert r.status_code == 409
    assert "id" not in r.json() and str(j["tanda"]) not in r.text
    # Su reintento de una tanda propia sigue devolviendo la suya.
    propio = str(uuid.uuid4())
    primera = c.post("/api/tandas", headers=a, json={"modelo_id": modelo, "cantidad": 1, "id_cliente": propio})
    otra = c.post("/api/tandas", headers=a, json={"modelo_id": modelo, "cantidad": 1, "id_cliente": propio})
    assert primera.status_code == 201 and otra.status_code == 200 and otra.json()["id"] == primera.json()["id"]
