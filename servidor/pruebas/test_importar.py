"""Pruebas del importador de perfiles.json (servidor/scripts/importar_perfiles.py).

Nunca se lee el perfiles.json real: cada prueba arma uno pequeno aqui mismo.
El servidor se reemplaza por un cliente HTTP falso con la misma forma
(post/get + atributo token) que usa el script.
"""

import json

import pytest

from servidor.scripts import importar_perfiles as imp


class HTTPFalso:
    """Servidor en memoria: lleva las listas y guarda las peticiones que recibe."""

    def __init__(self, clave="clave-buena"):
        self.token = None
        self.clave = clave
        self.perfiles = []
        self.filamentos = []
        self.peticiones = []

    def _exigir_sesion(self):
        if self.token != "token-de-prueba":
            raise imp.ErrorHTTP(401, "Hay que entrar")

    def post(self, ruta, cuerpo):
        self.peticiones.append(("POST", ruta, cuerpo))
        if ruta == "/api/acceso":
            if cuerpo["clave"] != self.clave:
                raise imp.ErrorHTTP(401, "Correo o contraseña incorrectos")
            return {"token": "token-de-prueba", "correo": cuerpo["correo"]}
        self._exigir_sesion()
        lista = {"/api/perfiles": self.perfiles, "/api/filamentos": self.filamentos}[ruta]
        creado = {"id": len(lista) + 1, **cuerpo}
        lista.append(creado)
        return creado

    def get(self, ruta):
        self.peticiones.append(("GET", ruta, None))
        self._exigir_sesion()
        return list({"/api/perfiles": self.perfiles, "/api/filamentos": self.filamentos}[ruta])


def _datos():
    return {
        "profiles": {
            "AD5M Casa": {
                "precioKg": "", "monedaFilamento": "COP", "precioKwh": "800", "consumoWatts": "300",
                "desgasteMaquina": "4000", "precioRepuestos": "120000", "monedaRepuestos": "COP",
                "manoObraHora": "20000", "margenError": "20", "precioDolar": "",
            },
            "Otro perfil": {"precioKwh": "1"},
        },
        "filamentos": [
            {"id": "fil_1", "marca": "CoLiDo", "color": "Black", "tipo": "PLA",
             "precio": 80000, "moneda": "COP", "hex": "#1b1b1b"},
            {"id": "fil_2", "marca": "CoLiDo", "color": "Clear", "tipo": "PLA",
             "precio": 72000.5, "moneda": "COP", "hex": "transparente"},
            {"id": "fil_3", "marca": "Sunlu", "color": "Red", "tipo": "PETG",
             "precio": 20, "moneda": "USD"},
        ],
        # Esto no se importa.
        "pieces": [{"x": 1}], "projects": {"p": 1}, "megaProjects": [], "empresas": [{"n": 1}],
    }


def _importar(http, datos=None):
    return imp.importar(http, "juan@ejemplo.com", "clave-buena", datos or _datos())


def test_importar_mapea_ad5m_casa():
    http = HTTPFalso()
    resumen = _importar(http)

    assert http.perfiles == [{
        "id": 1, "nombre": "AD5M Casa", "precio_kwh": 800.0, "consumo_watts": 300.0,
        "vida_maquina_h": 4000.0, "precio_repuestos": 120000.0, "margen_error": 20.0,
        "precio_dolar": None,
    }]
    assert http.filamentos[0] == {
        "id": 1, "marca": "CoLiDo", "tipo": "PLA", "color": "Black",
        "hex": "#1b1b1b", "precio_kg": 80000.0, "moneda": "COP",
    }
    # 'transparente' no es un color #RRGGBB: se omite en vez de hacer fallar el alta.
    assert "hex" not in http.filamentos[1] and http.filamentos[1]["precio_kg"] == 72000.5
    assert http.filamentos[2]["moneda"] == "USD"
    assert resumen == (1, 3)
    # Entro con correo y clave, y despues uso el token.
    assert http.peticiones[0] == ("POST", "/api/acceso", {"correo": "juan@ejemplo.com", "clave": "clave-buena"})
    assert http.token == "token-de-prueba"


def test_importar_dos_veces_no_duplica():
    http = HTTPFalso()
    assert _importar(http) == (1, 3)
    posts_primera_vez = [p for p in http.peticiones if p[0] == "POST" and p[1] != "/api/acceso"]
    assert len(posts_primera_vez) == 4

    # Segunda vez: mismo resultado en el resumen y ningun alta nueva.
    http.peticiones.clear()
    assert _importar(http) == (1, 3)
    assert [p for p in http.peticiones if p[0] == "POST" and p[1] != "/api/acceso"] == []
    assert len(http.perfiles) == 1 and len(http.filamentos) == 3


def test_importar_no_duplica_aunque_cambie_mayuscula_o_espacios():
    http = HTTPFalso()
    http.filamentos.append({"id": 1, "marca": " colido ", "tipo": "pla", "color": "BLACK",
                            "hex": None, "precio_kg": 1.0, "moneda": "COP"})
    _importar(http)
    assert len(http.filamentos) == 3  # el Black ya estaba; entran los otros dos


def test_importar_repetidos_dentro_del_archivo_entran_una_vez():
    datos = _datos()
    datos["filamentos"].append(dict(datos["filamentos"][0], id="fil_9"))
    http = HTTPFalso()
    assert _importar(http, datos) == (1, 3)
    assert len(http.filamentos) == 3


def test_importar_textos_vacios_son_cero_y_null():
    datos = _datos()
    datos["profiles"]["AD5M Casa"].update(precioKwh="", consumoWatts="  ", margenError="")
    http = HTTPFalso()
    _importar(http, datos)
    perfil = http.perfiles[0]
    assert perfil["precio_kwh"] == 0.0 and perfil["consumo_watts"] == 0.0 and perfil["margen_error"] == 0.0
    assert perfil["precio_dolar"] is None

    datos["profiles"]["AD5M Casa"]["precioDolar"] = "3950"
    http = HTTPFalso()
    _importar(http, datos)
    assert http.perfiles[0]["precio_dolar"] == 3950.0


def test_importar_sin_ad5m_casa_da_error_claro():
    datos = _datos()
    del datos["profiles"]["AD5M Casa"]
    http = HTTPFalso()
    with pytest.raises(imp.ErrorImportacion, match="AD5M Casa"):
        _importar(http, datos)
    # Ni siquiera entra al servidor: se revisa el archivo antes.
    assert http.peticiones == []


def test_importar_numero_ilegible_da_error_claro():
    datos = _datos()
    datos["profiles"]["AD5M Casa"]["precioKwh"] = "mucho"
    with pytest.raises(imp.ErrorImportacion, match="precioKwh"):
        _importar(HTTPFalso(), datos)


def test_importar_clave_mala():
    with pytest.raises(imp.ErrorHTTP) as e:
        imp.importar(HTTPFalso(), "juan@ejemplo.com", "otra", _datos())
    assert e.value.estado == 401


# ---------------------------------------------------------------------------
# Linea de comandos
# ---------------------------------------------------------------------------

def _archivo(tmp_path, datos):
    ruta = tmp_path / "perfiles.json"
    ruta.write_text(json.dumps(datos), encoding="utf-8")
    return str(ruta)


def test_principal_imprime_resumen(tmp_path, capsys):
    http = HTTPFalso()
    codigo = imp.principal(
        ["--perfiles", _archivo(tmp_path, _datos()), "--url", "https://x.example", "--correo", "juan@ejemplo.com"],
        http=http, pedir_clave=lambda _msg: "clave-buena")
    assert codigo == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == "Listo: 1 perfil, 3 filamentos"


def test_principal_singular_y_plural(tmp_path, capsys):
    datos = _datos()
    datos["filamentos"] = datos["filamentos"][:1]
    imp.principal(["--perfiles", _archivo(tmp_path, datos), "--url", "https://x.example", "--correo", "a@b.c"],
                  http=HTTPFalso(), pedir_clave=lambda _m: "clave-buena")
    assert capsys.readouterr().out.strip().splitlines()[-1] == "Listo: 1 perfil, 1 filamento"


def test_principal_errores_salen_en_espanol_con_codigo_1(tmp_path, capsys):
    datos = _datos()
    del datos["profiles"]["AD5M Casa"]
    args = ["--perfiles", _archivo(tmp_path, datos), "--url", "https://x.example", "--correo", "a@b.c"]
    assert imp.principal(args, http=HTTPFalso(), pedir_clave=lambda _m: "clave-buena") == 1
    assert "AD5M Casa" in capsys.readouterr().err

    # Clave equivocada.
    args = ["--perfiles", _archivo(tmp_path, _datos()), "--url", "https://x.example", "--correo", "a@b.c"]
    assert imp.principal(args, http=HTTPFalso(), pedir_clave=lambda _m: "mala") == 1
    assert "incorrectos" in capsys.readouterr().err

    # Archivo que no existe.
    assert imp.principal(["--perfiles", str(tmp_path / "no.json"), "--url", "https://x.example",
                          "--correo", "a@b.c"], http=HTTPFalso(), pedir_clave=lambda _m: "x") == 1
    assert "no.json" in capsys.readouterr().err
