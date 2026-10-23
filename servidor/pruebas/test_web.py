from fastapi.testclient import TestClient

from servidor.app.principal import crear_app


def _cliente(motores):
    return TestClient(crear_app(*motores))


def test_sin_la_variable_no_se_sirve_la_web(motores, monkeypatch):
    monkeypatch.delenv("SISTEMA_SERVIR_WEB", raising=False)
    cliente = _cliente(motores)
    assert cliente.get("/").status_code == 404
    assert cliente.get("/app.js").status_code == 404


def test_con_la_variable_se_sirve_la_web(motores, monkeypatch):
    monkeypatch.setenv("SISTEMA_SERVIR_WEB", "1")
    cliente = _cliente(motores)

    r = cliente.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "<title>3D Organizer</title>" in r.text

    for archivo, tipo in (("/app.js", "javascript"), ("/estilo.css", "css")):
        r = cliente.get(archivo)
        assert r.status_code == 200
        assert tipo in r.headers["content-type"]


def test_con_la_web_montada_la_api_sigue_respondiendo(motores, monkeypatch):
    monkeypatch.setenv("SISTEMA_SERVIR_WEB", "1")
    cliente = _cliente(motores)

    assert cliente.get("/health").json() == {"ok": True}
    # Sin sesion, la API contesta 401 (no la pagina ni un 404 del mount).
    assert cliente.get("/api/pedidos").status_code == 401
    assert cliente.get("/api/yo").status_code == 401
