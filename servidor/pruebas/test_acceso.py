import hashlib
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from servidor.app import acceso, base
from servidor.pruebas.conftest import CLAVE_JUAN, CORREO_JUAN, cifrar, poner_usuario

MENSAJE = "Correo o contraseña incorrectos"


def _ahora():
    # UTC sin zona: es como se guardan las fechas en la base.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def entrar(cliente, correo=CORREO_JUAN, clave=CLAVE_JUAN, **extra):
    return cliente.post("/api/acceso", json={"correo": correo, "clave": clave}, **extra)


@pytest.fixture
def con_juan(motores):
    poner_usuario(motores[1], CORREO_JUAN, CLAVE_JUAN)


def _sesion_directa(motor_sistema, token, correo=CORREO_JUAN, expira=None):
    """Inserta una sesion sin pasar por el login (para casos que el login no produce)."""
    with motor_sistema.begin() as con:
        con.execute(base.sesiones.insert().values(
            token_hash=hashlib.sha256(token.encode()).hexdigest(),
            correo=correo,
            creada=_ahora(),
            expira=expira or _ahora() + timedelta(days=1),
        ))


# --- verificar_clave -------------------------------------------------------

def test_verificar_clave_acepta_la_buena_y_rechaza_la_mala():
    huella = cifrar("secreta-123")
    assert acceso.verificar_clave("secreta-123", huella)
    assert not acceso.verificar_clave("otra-cosa", huella)


def test_verificar_clave_lee_el_n_guardado():
    # Las huellas de PrintoVerse llevan n=2^15 y las de prueba 2^14: debe
    # servir cualquiera, porque el n viaja dentro de la huella.
    assert acceso.verificar_clave("x" * 12, cifrar("x" * 12, n=1 << 12))
    assert acceso.verificar_clave("x" * 12, cifrar("x" * 12, n=1 << 15))


@pytest.mark.parametrize("guardado", ["", "basura", "bcrypt$1$2$3$aa$bb", "scrypt$x$8$1$zz$yy", None])
def test_verificar_clave_con_huella_rota_es_falso(guardado):
    assert acceso.verificar_clave("lo-que-sea", guardado) is False


# --- entrar ----------------------------------------------------------------

def test_entra_juan(cliente, motores, con_juan):
    respuesta = entrar(cliente)
    assert respuesta.status_code == 200
    cuerpo = respuesta.json()
    assert cuerpo["correo"] == CORREO_JUAN
    assert len(cuerpo["token"]) == 48

    # El token sirve en una ruta protegida.
    yo = cliente.get("/api/yo", headers={"Authorization": f"Bearer {cuerpo['token']}"})
    assert yo.status_code == 200
    assert yo.json() == {"correo": CORREO_JUAN, "dueno": True}

    # En la base solo queda la huella del token, nunca el token.
    with motores[0].connect() as con:
        filas = con.execute(select(base.sesiones)).all()
    assert len(filas) == 1
    assert filas[0].token_hash == hashlib.sha256(cuerpo["token"].encode()).hexdigest()
    assert cuerpo["token"] not in filas[0]


def test_la_cookie_sale_con_todas_sus_protecciones(cliente, con_juan):
    cookie = entrar(cliente).headers["set-cookie"].lower()
    assert cookie.startswith("sesion=")
    assert "httponly" in cookie
    assert "secure" in cookie
    assert "samesite=strict" in cookie
    assert f"max-age={180 * 24 * 3600}" in cookie


def test_correo_se_normaliza(cliente, con_juan):
    assert entrar(cliente, correo="  JUAN@Ejemplo.COM ").status_code == 200


def test_correo_no_permitido_aunque_exista(cliente, motores, con_juan):
    poner_usuario(motores[1], "otro@ejemplo.com", "otra-clave-buena")
    respuesta = entrar(cliente, "otro@ejemplo.com", "otra-clave-buena")
    assert respuesta.status_code == 401
    assert respuesta.json() == {"detail": MENSAJE}


def test_cuenta_inactiva(cliente, motores):
    poner_usuario(motores[1], CORREO_JUAN, CLAVE_JUAN, activo=0)
    respuesta = entrar(cliente)
    assert respuesta.status_code == 401
    assert respuesta.json() == {"detail": MENSAJE}


def test_debe_cambiar_clave(cliente, motores):
    poner_usuario(motores[1], CORREO_JUAN, CLAVE_JUAN, debe_cambiar=1)
    respuesta = entrar(cliente)
    assert respuesta.status_code == 401
    assert respuesta.json() == {"detail": MENSAJE}


def test_clave_mala(cliente, con_juan):
    respuesta = entrar(cliente, clave="no-es-esta")
    assert respuesta.status_code == 401
    assert respuesta.json() == {"detail": MENSAJE}


def test_correo_que_no_existe_da_el_mismo_mensaje(cliente, con_juan):
    respuesta = entrar(cliente, correo="nadie@ejemplo.com")
    assert respuesta.status_code == 401
    assert respuesta.json() == {"detail": MENSAJE}


def test_sin_correo_permitido_configurado_no_entra_nadie(cliente, con_juan, monkeypatch):
    # Si falta la variable el servicio debe cerrarse, no abrirse a todos.
    monkeypatch.delenv("SISTEMA_CORREO_PERMITIDO")
    assert entrar(cliente).status_code == 401


def test_correo_no_permitido_tambien_gasta_una_verificacion(cliente, con_juan, monkeypatch):
    # Para que tarde lo mismo que un correo valido (y no se pueda adivinar
    # cual es el permitido midiendo tiempos) se verifica contra la huella falsa.
    usados = []
    real = acceso.verificar_clave

    def espia(clave, guardado):
        usados.append(guardado)
        return real(clave, guardado)

    monkeypatch.setattr(acceso, "verificar_clave", espia)
    entrar(cliente, correo="otro@ejemplo.com")
    assert usados == [acceso.HUELLA_FALSA]


# --- limite de intentos ----------------------------------------------------

def test_cinco_fallos_bloquean(cliente, motores, con_juan):
    for _ in range(5):
        assert entrar(cliente, clave="mala").status_code == 401
    # El 6.o es 429 aunque la clave sea buena, y no abre ninguna sesion.
    respuesta = entrar(cliente)
    assert respuesta.status_code == 429
    with motores[0].connect() as con:
        assert con.execute(select(func.count()).select_from(base.sesiones)).scalar() == 0


def test_bloqueado_no_llega_a_verificar_la_clave(cliente, con_juan, monkeypatch):
    for _ in range(5):
        entrar(cliente, clave="mala")

    def no_debe_llamarse(*_):
        raise AssertionError("no se debe gastar scrypt con una IP bloqueada")

    monkeypatch.setattr(acceso, "verificar_clave", no_debe_llamarse)
    assert entrar(cliente).status_code == 429


def test_el_bloqueo_es_por_ip(cliente, con_juan):
    for _ in range(5):
        entrar(cliente, clave="mala", headers={"X-Real-IP": "203.0.113.7"})
    assert entrar(cliente, headers={"X-Real-IP": "203.0.113.7"}).status_code == 429
    # Otra IP no se ve afectada.
    assert entrar(cliente, headers={"X-Real-IP": "203.0.113.8"}).status_code == 200


def test_los_exitos_no_cuentan_como_fallos(cliente, con_juan):
    for _ in range(4):
        entrar(cliente, clave="mala")
    for _ in range(3):
        assert entrar(cliente).status_code == 200
    assert entrar(cliente, clave="mala").status_code == 401   # el 5.o fallo
    assert entrar(cliente).status_code == 429


def test_los_fallos_viejos_no_cuentan_y_se_limpian(cliente, motores, con_juan):
    viejo = _ahora() - timedelta(minutes=16)
    with motores[0].begin() as con:
        con.execute(base.intentos.insert(), [{"ip": "testclient", "momento": viejo}] * 5)
    assert entrar(cliente).status_code == 200
    with motores[0].connect() as con:
        assert con.execute(select(func.count()).select_from(base.intentos)).scalar() == 0


# --- rutas protegidas ------------------------------------------------------

def test_sin_token_401(cliente):
    assert cliente.get("/api/yo").status_code == 401


def test_token_inventado_401(cliente):
    assert cliente.get("/api/yo", headers={"Authorization": "Bearer " + "a" * 48}).status_code == 401


def test_token_vencido_401(cliente, motores):
    _sesion_directa(motores[0], "vencido", expira=_ahora() - timedelta(seconds=1))
    assert cliente.get("/api/yo", headers={"Authorization": "Bearer vencido"}).status_code == 401


def test_sesion_de_un_correo_que_ya_no_es_el_permitido_no_sirve(cliente, motores):
    _sesion_directa(motores[0], "ajeno", correo="otro@ejemplo.com")
    assert cliente.get("/api/yo", headers={"Authorization": "Bearer ajeno"}).status_code == 401


def test_la_cookie_sirve_para_leer(cliente, motores):
    _sesion_directa(motores[0], "de-cookie")
    cliente.cookies.set("sesion", "de-cookie")
    assert cliente.get("/api/yo").json() == {"correo": CORREO_JUAN, "dueno": True}


def test_cookie_sin_cabecera_x_sistema_403(cliente, motores):
    # Un POST con cookie sin X-Sistema es lo que mandaria otra pagina web
    # aprovechando la cookie del navegador (CSRF): se rechaza.
    _sesion_directa(motores[0], "de-cookie")
    cliente.cookies.set("sesion", "de-cookie")
    assert cliente.post("/api/salir").status_code == 403
    # Y la sesion sigue viva: el rechazo no la ha tocado.
    assert cliente.get("/api/yo").status_code == 200


def test_cookie_con_cabecera_x_sistema_pasa(cliente, motores):
    _sesion_directa(motores[0], "de-cookie")
    cliente.cookies.set("sesion", "de-cookie")
    assert cliente.post("/api/salir", headers={"X-Sistema": "1"}).status_code == 200


def test_bearer_no_necesita_x_sistema(cliente_con_sesion):
    # La app del iPhone manda el token a mano; CSRF solo afecta a cookies.
    assert cliente_con_sesion.post("/api/salir").status_code == 200


def test_salir_invalida_token(cliente, con_juan, motores):
    token = entrar(cliente).json()["token"]
    cabeceras = {"Authorization": f"Bearer {token}"}
    assert cliente.get("/api/yo", headers=cabeceras).status_code == 200
    assert cliente.post("/api/salir", headers=cabeceras).status_code == 200
    assert cliente.get("/api/yo", headers=cabeceras).status_code == 401
    with motores[0].connect() as con:
        assert con.execute(select(func.count()).select_from(base.sesiones)).scalar() == 0


def test_salir_sin_sesion_no_falla(cliente):
    assert cliente.post("/api/salir").status_code == 200


def test_cliente_con_sesion_ya_esta_dentro(cliente_con_sesion):
    assert cliente_con_sesion.get("/api/yo").json() == {"correo": CORREO_JUAN, "dueno": True}


# --- cuentas propias del sistema (ayudantes) --------------------------------

AMIGO = "amigo@ejemplo.com"
CLAVE_AMIGO = "clave-del-amigo-123"


def test_juan_crea_cuenta_y_el_amigo_entra_sin_ser_dueno(cliente_con_sesion):
    r = cliente_con_sesion.post("/api/usuarios", json={"correo": "Amigo@Ejemplo.com", "clave": CLAVE_AMIGO})
    assert r.status_code == 201 and r.json() == {"correo": AMIGO}
    assert [u["correo"] for u in cliente_con_sesion.get("/api/usuarios").json()] == [AMIGO]

    del cliente_con_sesion.headers["Authorization"]
    r = entrar(cliente_con_sesion, AMIGO, CLAVE_AMIGO)
    assert r.status_code == 200
    cabeceras = {"Authorization": f"Bearer {r.json()['token']}"}
    assert cliente_con_sesion.get("/api/yo", headers=cabeceras).json() == {"correo": AMIGO, "dueno": False}
    # Usa el sistema, pero no administra cuentas.
    assert cliente_con_sesion.get("/api/pedidos", headers=cabeceras).status_code == 200
    assert cliente_con_sesion.get("/api/usuarios", headers=cabeceras).status_code == 403
    assert cliente_con_sesion.post("/api/usuarios", headers=cabeceras,
                                   json={"correo": "otro@ejemplo.com", "clave": "x" * 12}).status_code == 403


def test_amigo_con_clave_mala_no_entra(cliente_con_sesion):
    cliente_con_sesion.post("/api/usuarios", json={"correo": AMIGO, "clave": CLAVE_AMIGO})
    del cliente_con_sesion.headers["Authorization"]
    r = entrar(cliente_con_sesion, AMIGO, "otra-clave-cualquiera")
    assert r.status_code == 401 and r.json()["detail"] == MENSAJE


def test_borrar_cuenta_corta_sus_sesiones(cliente_con_sesion):
    cliente_con_sesion.post("/api/usuarios", json={"correo": AMIGO, "clave": CLAVE_AMIGO})
    token_juan = cliente_con_sesion.headers.pop("Authorization")
    cabeceras = {"Authorization": f"Bearer {entrar(cliente_con_sesion, AMIGO, CLAVE_AMIGO).json()['token']}"}
    cliente_con_sesion.cookies.clear()
    cliente_con_sesion.headers["Authorization"] = token_juan
    assert cliente_con_sesion.delete(f"/api/usuarios/{AMIGO}").status_code == 204
    assert cliente_con_sesion.get("/api/yo", headers=cabeceras).status_code == 401
    assert cliente_con_sesion.delete(f"/api/usuarios/{AMIGO}").status_code == 404


def test_crear_cuenta_valida_datos(cliente_con_sesion):
    assert cliente_con_sesion.post("/api/usuarios", json={"correo": "no-es-correo", "clave": CLAVE_AMIGO}).status_code == 422
    assert cliente_con_sesion.post("/api/usuarios", json={"correo": AMIGO, "clave": "corta"}).status_code == 422
    assert cliente_con_sesion.post("/api/usuarios", json={"correo": CORREO_JUAN, "clave": CLAVE_AMIGO}).status_code == 409
    cliente_con_sesion.post("/api/usuarios", json={"correo": AMIGO, "clave": CLAVE_AMIGO})
    assert cliente_con_sesion.post("/api/usuarios", json={"correo": AMIGO, "clave": CLAVE_AMIGO}).status_code == 409


def test_usuarios_sin_sesion_401(cliente):
    assert cliente.get("/api/usuarios").status_code == 401
