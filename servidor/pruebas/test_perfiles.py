"""Pruebas de perfiles, filamentos y fotos de modelos."""

import hashlib

import pytest

PNG = b"\x89PNG\r\n\x1a\n" + b"datos-de-prueba" * 10
JPG = b"\xff\xd8\xff\xe0" + b"datos-de-prueba" * 10

PERFIL = {
    "nombre": "AD5M Casa", "precio_kwh": 655, "consumo_watts": 350,
    "vida_maquina_h": 5000, "precio_repuestos": 150000, "margen_error": 30,
}


@pytest.fixture
def carpeta_fotos(tmp_path, monkeypatch):
    # Cada prueba escribe en su propia carpeta temporal, nunca en /opt/sistema.
    monkeypatch.setenv("SISTEMA_FOTOS", str(tmp_path))
    return tmp_path


def _modelo_id(cliente) -> int:
    r = cliente.post("/api/pedidos", json={"nombre": "P", "modelos": [{"nombre": "M", "meta": 5}]})
    assert r.status_code == 201
    return r.json()["modelos"][0]["id"]


# ---------------------------------------------------------------------------
# Perfiles
# ---------------------------------------------------------------------------

def test_perfiles_requieren_sesion(cliente):
    assert cliente.get("/api/perfiles").status_code == 401
    assert cliente.get("/api/filamentos").status_code == 401


def test_perfiles_crud(cliente_con_sesion):
    c = cliente_con_sesion
    assert c.get("/api/perfiles").json() == []

    r = c.post("/api/perfiles", json={**PERFIL, "precio_dolar": 4000.5})
    assert r.status_code == 201
    primero = r.json()
    assert primero == {
        "id": primero["id"], "nombre": "AD5M Casa", "precio_kwh": 655.0, "consumo_watts": 350.0,
        "vida_maquina_h": 5000.0, "precio_repuestos": 150000.0, "margen_error": 30.0,
        "precio_dolar": 4000.5, "activo": True,
    }
    # Numeros de verdad en el JSON, no textos.
    assert isinstance(primero["precio_kwh"], float)

    # Sin precio_dolar queda en null.
    segundo = c.post("/api/perfiles", json={**PERFIL, "nombre": "Otro"}).json()
    assert segundo["precio_dolar"] is None
    assert segundo["activo"] is False  # el primero sigue siendo el activo

    assert [p["id"] for p in c.get("/api/perfiles").json()] == [primero["id"], segundo["id"]]

    r = c.patch(f"/api/perfiles/{segundo['id']}", json={"precio_kwh": 700.25, "precio_dolar": 3900})
    assert r.status_code == 200
    assert r.json()["precio_kwh"] == 700.25 and r.json()["precio_dolar"] == 3900.0
    # null borra el dolar; lo que no se manda no se toca.
    r = c.patch(f"/api/perfiles/{segundo['id']}", json={"precio_dolar": None})
    assert r.json()["precio_dolar"] is None and r.json()["precio_kwh"] == 700.25

    assert c.delete(f"/api/perfiles/{segundo['id']}").status_code == 204
    assert [p["id"] for p in c.get("/api/perfiles").json()] == [primero["id"]]


def test_no_borrar_ultimo_perfil(cliente_con_sesion):
    c = cliente_con_sesion
    uno = c.post("/api/perfiles", json=PERFIL).json()
    r = c.delete(f"/api/perfiles/{uno['id']}")
    assert r.status_code == 409
    assert len(c.get("/api/perfiles").json()) == 1


def test_un_solo_perfil_activo(cliente_con_sesion):
    c = cliente_con_sesion
    a = c.post("/api/perfiles", json=PERFIL).json()
    b = c.post("/api/perfiles", json={**PERFIL, "nombre": "B"}).json()
    d = c.post("/api/perfiles", json={**PERFIL, "nombre": "C"}).json()

    def activos():
        return [p["id"] for p in c.get("/api/perfiles").json() if p["activo"]]

    assert activos() == [a["id"]]
    # Activar uno apaga a los demas.
    assert c.patch(f"/api/perfiles/{d['id']}", json={"activo": True}).json()["activo"] is True
    assert activos() == [d["id"]]
    # Crear uno ya activo tambien deja uno solo.
    e = c.post("/api/perfiles", json={**PERFIL, "nombre": "E", "activo": True}).json()
    assert activos() == [e["id"]]
    # Apagar el unico activo dejaria a la app sin perfil: se rechaza.
    assert c.patch(f"/api/perfiles/{e['id']}", json={"activo": False}).status_code == 409
    assert activos() == [e["id"]]
    # Apagar uno que ya estaba apagado no cambia nada.
    assert c.patch(f"/api/perfiles/{b['id']}", json={"activo": False}).status_code == 200
    assert activos() == [e["id"]]
    # Borrar el activo pasa la marca al de id mas bajo.
    assert c.delete(f"/api/perfiles/{e['id']}").status_code == 204
    assert activos() == [a["id"]]


def test_perfil_nombre_repetido_409(cliente_con_sesion):
    c = cliente_con_sesion
    c.post("/api/perfiles", json=PERFIL)
    assert c.post("/api/perfiles", json=PERFIL).status_code == 409
    otro = c.post("/api/perfiles", json={**PERFIL, "nombre": "Otro"}).json()
    assert c.patch(f"/api/perfiles/{otro['id']}", json={"nombre": "AD5M Casa"}).status_code == 409


def test_perfil_inexistente_404(cliente_con_sesion):
    c = cliente_con_sesion
    assert c.patch("/api/perfiles/99", json={"precio_kwh": 1}).status_code == 404
    assert c.delete("/api/perfiles/99").status_code == 404
    assert c.patch("/api/perfiles/0", json={"precio_kwh": 1}).status_code == 422


@pytest.mark.parametrize("cambio", [
    {"precio_kwh": -1},
    {"consumo_watts": -0.5},
    {"vida_maquina_h": 0},          # es un divisor
    {"vida_maquina_h": -10},
    {"precio_repuestos": -1},
    {"margen_error": -1},
    {"margen_error": 1000.01},
    {"precio_dolar": -1},
    {"precio_kwh": "655"},          # los numeros llegan como numeros
    {"precio_kwh": True},
    {"precio_kwh": 1e15},           # no cabe en Numeric(14,2)
    {"precio_kwh": None},
    {"nombre": "   "},
    {"nombre": "x" * 81},
    {"activo": None},
])
def test_perfil_valores_invalidos_422(cliente_con_sesion, cambio):
    c = cliente_con_sesion
    assert c.post("/api/perfiles", json={**PERFIL, **cambio}).status_code == 422
    uno = c.post("/api/perfiles", json={**PERFIL, "nombre": "Valido"}).json()
    assert c.patch(f"/api/perfiles/{uno['id']}", json=cambio).status_code == 422


def test_perfil_margen_en_los_limites(cliente_con_sesion):
    c = cliente_con_sesion
    assert c.post("/api/perfiles", json={**PERFIL, "margen_error": 0}).status_code == 201
    assert c.post("/api/perfiles", json={**PERFIL, "nombre": "B", "margen_error": 1000}).status_code == 201


# ---------------------------------------------------------------------------
# Filamentos
# ---------------------------------------------------------------------------

FILAMENTO = {"marca": "CoLiDo", "tipo": "PLA", "color": "Black", "precio_kg": 70000, "moneda": "COP"}


def test_filamentos_crud(cliente_con_sesion):
    c = cliente_con_sesion
    assert c.get("/api/filamentos").json() == []
    r = c.post("/api/filamentos", json={**FILAMENTO, "hex": "#1b1b1b"})
    assert r.status_code == 201
    f = r.json()
    assert f == {"id": f["id"], "marca": "CoLiDo", "tipo": "PLA", "color": "Black",
                 "hex": "#1b1b1b", "precio_kg": 70000.0, "moneda": "COP"}
    # hex es opcional.
    sin_hex = c.post("/api/filamentos", json={**FILAMENTO, "color": "White", "moneda": "USD"}).json()
    assert sin_hex["hex"] is None and sin_hex["moneda"] == "USD"
    assert len(c.get("/api/filamentos").json()) == 2

    r = c.patch(f"/api/filamentos/{f['id']}", json={"precio_kg": 65000.5, "hex": None})
    assert r.status_code == 200
    assert r.json()["precio_kg"] == 65000.5 and r.json()["hex"] is None and r.json()["marca"] == "CoLiDo"

    assert c.delete(f"/api/filamentos/{f['id']}").status_code == 204
    assert c.delete(f"/api/filamentos/{f['id']}").status_code == 404
    assert c.patch(f"/api/filamentos/{f['id']}", json={"precio_kg": 1}).status_code == 404


@pytest.mark.parametrize("cambio", [
    {"moneda": "EUR"},
    {"moneda": "cop"},
    {"hex": "transparente"},
    {"hex": "#12345"},
    {"hex": "#GGGGGG"},
    {"hex": "1b1b1b"},
    {"precio_kg": -1},
    {"precio_kg": "70000"},
    {"marca": ""},
    {"marca": "x" * 61},
    {"tipo": "x" * 31},
    {"color": "x" * 41},
    {"color": None},
])
def test_filamento_valores_invalidos_422(cliente_con_sesion, cambio):
    c = cliente_con_sesion
    assert c.post("/api/filamentos", json={**FILAMENTO, **cambio}).status_code == 422
    f = c.post("/api/filamentos", json=FILAMENTO).json()
    assert c.patch(f"/api/filamentos/{f['id']}", json=cambio).status_code == 422


# ---------------------------------------------------------------------------
# Fotos
# ---------------------------------------------------------------------------

def test_foto_png_valida_y_lectura_con_sesion(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    modelo = _modelo_id(c)
    r = c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", PNG, "image/png")})
    assert r.status_code == 200
    nombre = hashlib.sha256(PNG).hexdigest() + ".png"
    cuerpo = r.json()
    assert cuerpo["id"] == modelo and cuerpo["foto_url"] == f"/api/fotos/{nombre}"
    assert cuerpo["meta"] == 5 and cuerpo["hechas"] == 0  # es el modelo completo
    assert (carpeta_fotos / nombre).read_bytes() == PNG
    assert [p.name for p in carpeta_fotos.iterdir()] == [nombre]  # sin temporales sueltos

    # La foto aparece tambien en el detalle del pedido.
    pedido = c.get("/api/pedidos").json()[0]["id"]
    assert c.get(f"/api/pedidos/{pedido}").json()["modelos"][0]["foto_url"] == cuerpo["foto_url"]

    r = c.get(cuerpo["foto_url"])
    assert r.status_code == 200 and r.content == PNG
    assert r.headers["content-type"] == "image/png"
    assert r.headers["cache-control"] == "private, max-age=31536000, immutable"

    # Sin sesion no se ve.
    c.headers.pop("Authorization")
    assert c.get(cuerpo["foto_url"]).status_code == 401


def test_foto_jpeg_y_reemplazo(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    modelo = _modelo_id(c)
    c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", PNG, "image/png")})
    # El tipo se decide por los bytes, no por el nombre ni por lo que diga el cliente.
    r = c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", JPG, "image/png")})
    assert r.status_code == 200
    nombre = hashlib.sha256(JPG).hexdigest() + ".jpg"
    assert r.json()["foto_url"] == f"/api/fotos/{nombre}"
    leida = c.get(r.json()["foto_url"])
    assert leida.headers["content-type"] == "image/jpeg" and leida.content == JPG
    # Subir la misma foto otra vez no falla.
    assert c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("b.jpg", JPG, "image/jpeg")}).status_code == 200


def test_foto_que_no_es_imagen_415(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    modelo = _modelo_id(c)
    for contenido in (b"<?php echo 1; ?>", b"GIF89a....", b"", b"\x89PNG"):
        r = c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", contenido, "image/png")})
        assert r.status_code == 415, contenido
    assert list(carpeta_fotos.iterdir()) == []
    assert c.get("/api/pedidos").json()  # sigue vivo
    assert c.get(f"/api/pedidos/{c.get('/api/pedidos').json()[0]['id']}").json()["modelos"][0]["foto_url"] is None


def test_foto_demasiado_grande_413(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    modelo = _modelo_id(c)
    limite = 3 * 1024 * 1024
    justo = PNG + b"0" * (limite - len(PNG))
    assert c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", justo, "image/png")}).status_code == 200
    pasado = justo + b"0"
    r = c.put(f"/api/modelos/{modelo}/foto", files={"foto": ("a.png", pasado, "image/png")})
    assert r.status_code == 413
    assert [p.name for p in carpeta_fotos.iterdir()] == [hashlib.sha256(justo).hexdigest() + ".png"]


def test_foto_sin_archivo_o_modelo_inexistente(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    modelo = _modelo_id(c)
    assert c.put(f"/api/modelos/{modelo}/foto").status_code == 422
    assert c.put("/api/modelos/999/foto", files={"foto": ("a.png", PNG, "image/png")}).status_code == 404
    assert list(carpeta_fotos.iterdir()) == []


def test_foto_requiere_sesion(cliente, carpeta_fotos):
    r = cliente.put("/api/modelos/1/foto", files={"foto": ("a.png", PNG, "image/png")})
    assert r.status_code == 401


def test_nombre_de_foto_con_puntos_404(cliente_con_sesion, carpeta_fotos):
    c = cliente_con_sesion
    # Un archivo secreto junto a las fotos: ninguna ruta rara debe llegar a el.
    (carpeta_fotos.parent / ".env").write_text("SECRETO")
    (carpeta_fotos / ".env").write_text("SECRETO")
    valido_pero_ausente = "a" * 64 + ".png"
    for nombre in ("../.env", "..%2F.env", "%2e%2e%2f.env", ".env", "a.png",
                   "a" * 64 + ".gif", "A" * 64 + ".png", "a" * 63 + ".png",
                   "a" * 64 + ".png.png", "a" * 64 + "..png", valido_pero_ausente):
        r = c.get(f"/api/fotos/{nombre}")
        assert r.status_code == 404, nombre
        assert "SECRETO" not in r.text
