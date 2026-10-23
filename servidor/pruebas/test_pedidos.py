import uuid
from datetime import datetime

import pytest

from servidor.app import base, pedidos

# "Ahora" fijo de las pruebas: 23 de octubre de 2026, 15:00 en Bogota.
AHORA = datetime(2026, 10, 23, 15, 0)


@pytest.fixture(autouse=True)
def hora_fija(monkeypatch):
    monkeypatch.setattr(pedidos, "ahora_bogota", lambda: AHORA)


def nuevo_uuid():
    return str(uuid.uuid4())


def crear_pedido(c, **extra):
    cuerpo = {
        "nombre": "Pedido Navidad",
        "cliente": "Tienda Centro",
        "entrega": "2026-11-20",
        "modelos": [{"nombre": "Dragon", "meta": 1000}, {"nombre": "Zooki", "meta": 500}],
    }
    cuerpo.update(extra)
    r = c.post("/api/pedidos", json=cuerpo)
    assert r.status_code == 201, r.text
    return r.json()


def poner_tanda(c, modelo_id, cantidad, **extra):
    cuerpo = {"modelo_id": modelo_id, "cantidad": cantidad, "id_cliente": nuevo_uuid()}
    cuerpo.update(extra)
    return c.post("/api/tandas", json=cuerpo)


# --- Crear y ver ------------------------------------------------------------

def test_crear_y_ver_detalle(cliente_con_sesion):
    c = cliente_con_sesion
    creado = crear_pedido(c, nota="Embalar aparte")
    assert creado["nombre"] == "Pedido Navidad"
    assert creado["estado"] == "abierto"
    assert creado["entrega"] == "2026-11-20"
    assert creado["nota"] == "Embalar aparte"
    assert [m["nombre"] for m in creado["modelos"]] == ["Dragon", "Zooki"]
    assert creado["modelos"][0] == {
        "id": creado["modelos"][0]["id"], "nombre": "Dragon", "meta": 1000, "hechas": 0,
        "foto_url": None, "completo": False, "de_mas": 0, "faltan": 1000}
    assert creado["avance"] == {
        "hechas_total": 0, "meta_total": 1500, "contadas": 0, "faltan": 1500, "porcentaje": 0}
    # Hoy 23/10 -> entrega 20/11 = 29 dias; 1500/29 = 51,7 -> 52 por dia.
    assert creado["ritmo"] == {"dias": 29, "por_dia": 52, "vencido": False}
    assert creado["ultimas_tandas"] == []

    visto = c.get(f"/api/pedidos/{creado['id']}")
    assert visto.status_code == 200
    assert visto.json() == creado

    lista = c.get("/api/pedidos").json()
    assert len(lista) == 1
    assert lista[0]["id"] == creado["id"]
    assert lista[0]["num_modelos"] == 2
    assert lista[0]["avance"]["meta_total"] == 1500
    assert lista[0]["ritmo"]["por_dia"] == 52
    assert "modelos" not in lista[0]


def test_crear_pedido_con_solo_lo_obligatorio(cliente_con_sesion):
    r = cliente_con_sesion.post("/api/pedidos", json={
        "nombre": "Suelto", "modelos": [{"nombre": "Uno", "meta": 5}]})
    assert r.status_code == 201
    d = r.json()
    assert d["cliente"] is None and d["entrega"] is None and d["ritmo"] is None


def test_foto_url_sale_de_la_foto_guardada(cliente_con_sesion, motores):
    creado = crear_pedido(cliente_con_sesion)
    with motores[0].begin() as con:
        con.execute(base.modelos.update().where(
            base.modelos.c.id == creado["modelos"][0]["id"]).values(foto="abc123.jpg"))
    d = cliente_con_sesion.get(f"/api/pedidos/{creado['id']}").json()
    assert d["modelos"][0]["foto_url"] == "/api/fotos/abc123.jpg"
    assert d["modelos"][1]["foto_url"] is None


@pytest.mark.parametrize("cuerpo", [
    {"nombre": "", "modelos": [{"nombre": "A", "meta": 1}]},
    {"nombre": "   ", "modelos": [{"nombre": "A", "meta": 1}]},
    {"nombre": "x" * 121, "modelos": [{"nombre": "A", "meta": 1}]},
    {"nombre": "P", "modelos": []},
    {"nombre": "P", "modelos": [{"nombre": "A", "meta": 1}] * 51},
    {"nombre": "P", "modelos": [{"nombre": "", "meta": 1}]},
    {"nombre": "P", "modelos": [{"nombre": "A", "meta": 0}]},
    {"nombre": "P", "modelos": [{"nombre": "A", "meta": 1000001}]},
    {"nombre": "P", "modelos": [{"nombre": "A", "meta": "mucho"}]},
    {"nombre": "P", "entrega": "manana", "modelos": [{"nombre": "A", "meta": 1}]},
    {"nombre": "P", "entrega": "0001-01-01", "modelos": [{"nombre": "A", "meta": 1}]},
])
def test_crear_pedido_invalido_422(cliente_con_sesion, cuerpo):
    assert cliente_con_sesion.post("/api/pedidos", json=cuerpo).status_code == 422


def test_el_modelo_51_de_un_pedido_da_409(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c, modelos=[{"nombre": f"M{i}", "meta": 1} for i in range(50)])
    r = c.post(f"/api/pedidos/{d['id']}/modelos", json={"nombre": "Otro", "meta": 1})
    assert r.status_code == 409


def test_entrega_vencida_se_informa_sin_dividir(cliente_con_sesion):
    d = crear_pedido(cliente_con_sesion, entrega="2026-10-20")
    assert d["ritmo"] == {"dias": -2, "por_dia": None, "vencido": True, "vencido_hace": 3}


def test_ids_inexistentes_dan_404(cliente_con_sesion):
    c = cliente_con_sesion
    assert c.get("/api/pedidos/999").status_code == 404
    assert c.patch("/api/pedidos/999", json={"nombre": "x"}).status_code == 404
    assert c.get("/api/pedidos/999/tandas").status_code == 404
    assert c.post("/api/pedidos/999/modelos", json={"nombre": "A", "meta": 1}).status_code == 404
    assert c.patch("/api/modelos/999", json={"meta": 3}).status_code == 404
    assert c.delete("/api/modelos/999").status_code == 404
    assert poner_tanda(c, 999, 5).status_code == 404
    assert c.patch("/api/tandas/999", json={"cantidad": 3}).status_code == 404
    assert c.delete("/api/tandas/999").status_code == 404


def test_id_enorme_en_la_ruta_es_422_no_500(cliente_con_sesion):
    assert cliente_con_sesion.get(f"/api/pedidos/{10**30}").status_code == 422


# --- Tandas -----------------------------------------------------------------

def test_tanda_suma_al_modelo(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    r = poner_tanda(c, dragon, 50, cuando="2026-10-23T10:00:00-05:00")
    assert r.status_code == 201
    t = r.json()
    assert t["modelo_id"] == dragon and t["modelo"] == "Dragon" and t["cantidad"] == 50
    assert t["cuando"] == "2026-10-23T10:00:00-05:00"
    assert poner_tanda(c, dragon, 70, cuando="2026-10-23T14:00:00-05:00").status_code == 201

    d = c.get(f"/api/pedidos/{d['id']}").json()
    assert d["modelos"][0]["hechas"] == 120
    assert d["modelos"][0]["faltan"] == 880
    assert d["modelos"][1]["hechas"] == 0
    assert d["avance"]["contadas"] == 120 and d["avance"]["faltan"] == 1380
    assert [x["cantidad"] for x in d["ultimas_tandas"]] == [70, 50]


def test_pasarse_de_meta_se_permite(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c, modelos=[{"nombre": "Dragon", "meta": 1000}])
    dragon = d["modelos"][0]["id"]
    assert poner_tanda(c, dragon, 1012, cuando="2026-10-23T10:00:00-05:00").status_code == 201
    m = c.get(f"/api/pedidos/{d['id']}").json()["modelos"][0]
    assert m["hechas"] == 1012 and m["completo"] is True
    assert m["de_mas"] == 12 and m["faltan"] == 0


def test_lo_de_mas_de_un_modelo_no_tapa_a_los_otros(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c, modelos=[{"nombre": "A", "meta": 10}, {"nombre": "B", "meta": 10}])
    poner_tanda(c, d["modelos"][0]["id"], 15)
    av = c.get(f"/api/pedidos/{d['id']}").json()["avance"]
    assert av["hechas_total"] == 15 and av["contadas"] == 10 and av["faltan"] == 10
    assert av["porcentaje"] == 50


def test_tanda_parecida_da_409_y_con_forzar_201(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    primera = poner_tanda(c, dragon, 50, cuando="2026-10-23T15:02:00-05:00").json()

    r = poner_tanda(c, dragon, 50, cuando="2026-10-23T15:42:00-05:00")
    assert r.status_code == 409
    assert r.json()["parecida"] == {
        "id": primera["id"], "cantidad": 50,
        "cuando": "2026-10-23T15:02:00-05:00", "hace_minutos": 40}

    # Misma cantidad pero 4 h despues, u otra cantidad: no es parecida.
    assert poner_tanda(c, dragon, 50, cuando="2026-10-23T19:10:00-05:00").status_code == 201
    assert poner_tanda(c, dragon, 49, cuando="2026-10-23T15:42:00-05:00").status_code == 201

    # Con forzar si entra, y queda registrada.
    r = poner_tanda(c, dragon, 50, cuando="2026-10-23T15:42:00-05:00", forzar=True)
    assert r.status_code == 201
    assert len(c.get(f"/api/pedidos/{d['id']}/tandas").json()) == 4


def test_409_usa_la_parecida_mas_reciente_y_el_tiempo_es_absoluto(cliente_con_sesion):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    poner_tanda(c, dragon, 50, cuando="2026-10-23T12:30:00-05:00")
    reciente = poner_tanda(c, dragon, 50, cuando="2026-10-23T14:00:00-05:00", forzar=True).json()
    # Se anota una tanda "del pasado" que se parece a ambas: gana la mas reciente.
    r = poner_tanda(c, dragon, 50, cuando="2026-10-23T13:30:00-05:00")
    assert r.status_code == 409
    assert r.json()["parecida"]["id"] == reciente["id"]
    assert r.json()["parecida"]["hace_minutos"] == 30


def test_parecida_solo_se_compara_con_el_mismo_modelo(cliente_con_sesion):
    c = cliente_con_sesion
    modelos = crear_pedido(c)["modelos"]
    assert poner_tanda(c, modelos[0]["id"], 50, cuando="2026-10-23T15:02:00-05:00").status_code == 201
    assert poner_tanda(c, modelos[1]["id"], 50, cuando="2026-10-23T15:10:00-05:00").status_code == 201


def test_mismo_id_cliente_dos_veces_una_sola_tanda(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    ident = nuevo_uuid()
    primera = poner_tanda(c, dragon, 50, id_cliente=ident, cuando="2026-10-23T15:02:00-05:00")
    assert primera.status_code == 201
    # El reintento (misma tanda, por timeout) devuelve la que ya estaba. Aunque
    # ahora se parezca a si misma, nunca debe dar 409.
    segunda = poner_tanda(c, dragon, 50, id_cliente=ident, cuando="2026-10-23T15:02:00-05:00")
    assert segunda.status_code == 200
    assert segunda.json() == primera.json()
    # En mayusculas (asi manda los UUID el iPhone) es la misma tanda.
    tercera = poner_tanda(c, dragon, 50, id_cliente=ident.upper(), cuando="2026-10-23T15:20:00-05:00")
    assert tercera.status_code == 200 and tercera.json()["id"] == primera.json()["id"]
    assert len(c.get(f"/api/pedidos/{d['id']}/tandas").json()) == 1
    assert c.get(f"/api/pedidos/{d['id']}").json()["modelos"][0]["hechas"] == 50


def test_id_cliente_que_choca_en_carrera_devuelve_la_existente(cliente_con_sesion, monkeypatch):
    # Dos envios simultaneos: ambos ven "no existe" y el segundo INSERT choca
    # con el UNIQUE. Debe contestar 200 con la tanda ganadora, no 500.
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    ident = nuevo_uuid()
    primera = poner_tanda(c, dragon, 50, id_cliente=ident).json()
    original = pedidos._buscar_por_id_cliente
    llamadas = []

    def ciega_la_primera_vez(con, id_cliente):
        llamadas.append(1)
        return None if len(llamadas) == 1 else original(con, id_cliente)

    monkeypatch.setattr(pedidos, "_buscar_por_id_cliente", ciega_la_primera_vez)
    # forzar: la tanda ya existente se parece a esta y sin el no se llegaria al INSERT.
    r = poner_tanda(c, dragon, 50, id_cliente=ident, forzar=True)
    assert r.status_code == 200 and r.json()["id"] == primera["id"]


@pytest.mark.parametrize("cantidad", [0, -3, "abc", 100001, 5.5, None, True, "7"])
def test_cantidad_invalida_422(cliente_con_sesion, cantidad):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    assert poner_tanda(c, dragon, cantidad).status_code == 422


def test_cantidad_en_los_limites(cliente_con_sesion):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    assert poner_tanda(c, dragon, 1, cuando="2026-10-23T01:00:00-05:00").status_code == 201
    assert poner_tanda(c, dragon, 100000, cuando="2026-10-23T01:00:00-05:00").status_code == 201


@pytest.mark.parametrize("extra", [
    {"id_cliente": "no-es-uuid"},
    {"id_cliente": ""},
    {"cuando": "ayer"},
    {"cuando": 1700000000},
    {"cuando": "0001-01-01T00:00:00"},
    # En los bordes del calendario, convertir de zona desborda datetime.
    {"cuando": "0001-01-01T00:00:00+05:00"},
    {"cuando": "9999-12-31T23:00:00-05:00"},
    {"modelo_id": 0},
    {"modelo_id": 10**30},
])
def test_tanda_con_campos_invalidos_422(cliente_con_sesion, extra):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    cuerpo = {"modelo_id": dragon, "cantidad": 5, "id_cliente": nuevo_uuid()}
    cuerpo.update(extra)
    assert c.post("/api/tandas", json=cuerpo).status_code == 422


def test_sin_cuando_se_usa_la_hora_de_bogota(cliente_con_sesion):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    t = poner_tanda(c, dragon, 5).json()
    assert t["cuando"] == "2026-10-23T15:00:00-05:00"


def test_cuando_con_otra_zona_se_pasa_a_bogota_y_sin_zona_se_toma_como_bogota(cliente_con_sesion):
    c = cliente_con_sesion
    dragon = crear_pedido(c)["modelos"][0]["id"]
    utc = poner_tanda(c, dragon, 1, cuando="2026-10-23T20:02:00Z").json()
    assert utc["cuando"] == "2026-10-23T15:02:00-05:00"
    madrid = poner_tanda(c, dragon, 2, cuando="2026-10-23T22:02:00+02:00").json()
    assert madrid["cuando"] == "2026-10-23T15:02:00-05:00"
    ingenua = poner_tanda(c, dragon, 3, cuando="2026-10-23T09:30:00").json()
    assert ingenua["cuando"] == "2026-10-23T09:30:00-05:00"


def test_borrar_y_editar_tanda(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    t = poner_tanda(c, dragon, 50, cuando="2026-10-23T10:00:00-05:00").json()

    r = c.patch(f"/api/tandas/{t['id']}", json={"cantidad": 60, "cuando": "2026-10-23T11:30:00-05:00"})
    assert r.status_code == 200
    assert r.json()["cantidad"] == 60 and r.json()["cuando"] == "2026-10-23T11:30:00-05:00"
    assert c.get(f"/api/pedidos/{d['id']}").json()["modelos"][0]["hechas"] == 60

    # Cuerpo vacio: no cambia nada.
    assert c.patch(f"/api/tandas/{t['id']}", json={}).json()["cantidad"] == 60
    assert c.patch(f"/api/tandas/{t['id']}", json={"cantidad": 0}).status_code == 422
    assert c.patch(f"/api/tandas/{t['id']}", json={"cantidad": None}).status_code == 422
    for cuando in ("0001-01-01T00:00:00+05:00", "9999-12-31T23:00:00-05:00"):
        assert c.patch(f"/api/tandas/{t['id']}", json={"cuando": cuando}).status_code == 422

    r = c.delete(f"/api/tandas/{t['id']}")
    assert r.status_code == 204 and r.content == b""
    assert c.get(f"/api/pedidos/{d['id']}").json()["modelos"][0]["hechas"] == 0
    assert c.get(f"/api/pedidos/{d['id']}/tandas").json() == []
    assert c.delete(f"/api/tandas/{t['id']}").status_code == 404


def test_listar_tandas_de_la_mas_nueva_a_la_mas_vieja_y_filtrar_por_modelo(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon, zooki = d["modelos"][0]["id"], d["modelos"][1]["id"]
    poner_tanda(c, dragon, 10, cuando="2026-10-23T09:00:00-05:00")
    poner_tanda(c, zooki, 20, cuando="2026-10-23T13:00:00-05:00")
    poner_tanda(c, dragon, 30, cuando="2026-10-23T11:00:00-05:00")

    todas = c.get(f"/api/pedidos/{d['id']}/tandas").json()
    assert [t["cantidad"] for t in todas] == [20, 30, 10]
    assert set(todas[0]) == {"id", "modelo_id", "modelo", "cantidad", "cuando", "id_cliente"}
    assert todas[0]["modelo"] == "Zooki"

    solo = c.get(f"/api/pedidos/{d['id']}/tandas", params={"modelo_id": dragon}).json()
    assert [t["cantidad"] for t in solo] == [30, 10]

    # Un modelo de otro pedido no se cuela en este.
    otro = crear_pedido(c, nombre="Otro")["modelos"][0]["id"]
    assert c.get(f"/api/pedidos/{d['id']}/tandas", params={"modelo_id": otro}).json() == []


def test_ultimas_tandas_son_las_5_mas_recientes(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    for hora in range(7):
        poner_tanda(c, dragon, 10 + hora, cuando=f"2026-10-23T0{hora}:00:00-05:00")
    ult = c.get(f"/api/pedidos/{d['id']}").json()["ultimas_tandas"]
    assert [t["cantidad"] for t in ult] == [16, 15, 14, 13, 12]


# --- Modelos ----------------------------------------------------------------

def test_agregar_editar_y_borrar_modelo(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    r = c.post(f"/api/pedidos/{d['id']}/modelos", json={"nombre": "Llavero", "meta": 200})
    assert r.status_code == 201
    m = r.json()
    assert m["nombre"] == "Llavero" and m["meta"] == 200 and m["hechas"] == 0 and m["faltan"] == 200

    r = c.patch(f"/api/modelos/{m['id']}", json={"nombre": "Llavero XL", "meta": 300})
    assert r.status_code == 200 and r.json()["nombre"] == "Llavero XL" and r.json()["meta"] == 300
    assert c.patch(f"/api/modelos/{m['id']}", json={"meta": 0}).status_code == 422
    assert c.patch(f"/api/modelos/{m['id']}", json={"nombre": ""}).status_code == 422

    detalle = c.get(f"/api/pedidos/{d['id']}").json()
    assert [x["nombre"] for x in detalle["modelos"]] == ["Dragon", "Zooki", "Llavero XL"]
    assert detalle["avance"]["meta_total"] == 1800

    assert c.delete(f"/api/modelos/{m['id']}").status_code == 204
    assert len(c.get(f"/api/pedidos/{d['id']}").json()["modelos"]) == 2


def test_bajar_la_meta_por_debajo_de_lo_hecho_se_permite(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    poner_tanda(c, dragon, 100)
    m = c.patch(f"/api/modelos/{dragon}", json={"meta": 80}).json()
    assert m["completo"] is True and m["de_mas"] == 20 and m["faltan"] == 0


def test_borrar_modelo_con_tandas_409(cliente_con_sesion):
    c = cliente_con_sesion
    d = crear_pedido(c)
    dragon = d["modelos"][0]["id"]
    t = poner_tanda(c, dragon, 5).json()
    assert c.delete(f"/api/modelos/{dragon}").status_code == 409
    # Sigue estando, con su tanda.
    assert len(c.get(f"/api/pedidos/{d['id']}").json()["modelos"]) == 2
    # Sin la tanda ya se puede borrar.
    c.delete(f"/api/tandas/{t['id']}")
    assert c.delete(f"/api/modelos/{dragon}").status_code == 204


# --- Pedidos: estado y listas ------------------------------------------------

def test_terminados_no_salen_en_abiertos(cliente_con_sesion):
    c = cliente_con_sesion
    a = crear_pedido(c, nombre="Abierto")
    t = crear_pedido(c, nombre="Cerrado")
    r = c.patch(f"/api/pedidos/{t['id']}", json={"estado": "terminado"})
    assert r.status_code == 200 and r.json()["estado"] == "terminado"

    abiertos = c.get("/api/pedidos", params={"estado": "abierto"}).json()
    assert [p["id"] for p in abiertos] == [a["id"]]
    terminados = c.get("/api/pedidos", params={"estado": "terminado"}).json()
    assert [p["id"] for p in terminados] == [t["id"]]
    assert len(c.get("/api/pedidos").json()) == 2
    assert c.get("/api/pedidos", params={"estado": "otro"}).status_code == 422


def test_terminar_pone_la_fecha_y_reabrir_la_quita(cliente_con_sesion):
    c = cliente_con_sesion
    p = crear_pedido(c)
    assert p["terminado_en"] is None
    cerrado = c.patch(f"/api/pedidos/{p['id']}", json={"estado": "terminado"}).json()
    assert cerrado["terminado_en"] == "2026-10-23T15:00:00-05:00"
    # Un pedido cerrado no muestra ritmo: ya no hay nada que repartir.
    assert cerrado["ritmo"] is None
    reabierto = c.patch(f"/api/pedidos/{p['id']}", json={"estado": "abierto"}).json()
    assert reabierto["terminado_en"] is None and reabierto["ritmo"] is not None


def test_editar_pedido_y_borrar_campos_opcionales(cliente_con_sesion):
    c = cliente_con_sesion
    p = crear_pedido(c, nota="algo")
    r = c.patch(f"/api/pedidos/{p['id']}", json={
        "nombre": "Nuevo nombre", "cliente": None, "entrega": None, "nota": ""})
    assert r.status_code == 200
    d = r.json()
    assert d["nombre"] == "Nuevo nombre" and d["cliente"] is None and d["entrega"] is None
    assert d["ritmo"] is None
    # Lo que no se manda no se toca.
    d = c.patch(f"/api/pedidos/{p['id']}", json={"cliente": "Ana"}).json()
    assert d["nombre"] == "Nuevo nombre" and d["cliente"] == "Ana"
    assert c.patch(f"/api/pedidos/{p['id']}", json={"nombre": None}).status_code == 422
    assert c.patch(f"/api/pedidos/{p['id']}", json={"estado": "cancelado"}).status_code == 422


def test_lista_ordena_por_entrega_y_deja_al_final_los_sin_fecha(cliente_con_sesion):
    c = cliente_con_sesion
    sin = crear_pedido(c, nombre="Sin fecha", entrega=None)
    tarde = crear_pedido(c, nombre="Tarde", entrega="2026-12-01")
    pronto = crear_pedido(c, nombre="Pronto", entrega="2026-11-01")
    ids = [p["id"] for p in c.get("/api/pedidos").json()]
    assert ids == [pronto["id"], tarde["id"], sin["id"]]


def test_tanda_de_un_pedido_terminado_se_permite(cliente_con_sesion):
    # Juan puede anotar una tanda atrasada despues de cerrar el pedido.
    c = cliente_con_sesion
    d = crear_pedido(c)
    c.patch(f"/api/pedidos/{d['id']}", json={"estado": "terminado"})
    assert poner_tanda(c, d["modelos"][0]["id"], 5).status_code == 201


# --- Acceso -----------------------------------------------------------------

@pytest.mark.parametrize("metodo,ruta", [
    ("get", "/api/pedidos"), ("post", "/api/pedidos"), ("get", "/api/pedidos/1"),
    ("patch", "/api/pedidos/1"), ("get", "/api/pedidos/1/tandas"),
    ("post", "/api/pedidos/1/modelos"), ("patch", "/api/modelos/1"),
    ("delete", "/api/modelos/1"), ("post", "/api/tandas"),
    ("patch", "/api/tandas/1"), ("delete", "/api/tandas/1"),
])
def test_todas_las_rutas_exigen_sesion(cliente, metodo, ruta):
    assert getattr(cliente, metodo)(ruta).status_code == 401


def test_post_con_cookie_sin_x_sistema_da_403(cliente_con_sesion):
    c = cliente_con_sesion
    token = c.headers.pop("Authorization")[len("Bearer "):]
    cuerpo = {"nombre": "P", "modelos": [{"nombre": "A", "meta": 1}]}
    # La cookie va a mano en la cabecera: la de /api/acceso es secure y el
    # cliente de pruebas (http) no la mandaria sola.
    galleta = {"Cookie": f"sesion={token}"}
    assert c.post("/api/pedidos", json=cuerpo, headers=galleta).status_code == 403
    assert c.get("/api/pedidos").status_code == 401  # sin Bearer ni cookie
    assert c.get("/api/pedidos", headers=galleta).status_code == 200
    ok = c.post("/api/pedidos", json=cuerpo, headers={**galleta, "X-Sistema": "1"})
    assert ok.status_code == 201
