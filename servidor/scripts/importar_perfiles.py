"""
importar_perfiles.py - Copia unica del perfil y los filamentos de la calculadora.

Lee el perfiles.json de la calculadora de escritorio y crea en el sistema el
perfil "AD5M Casa" y todos los filamentos. Se puede repetir sin miedo: lo que
ya existe se salta.

Uso, desde la carpeta del repositorio:
    python servidor\\scripts\\importar_perfiles.py --perfiles RUTA\\perfiles.json ^
        --url https://sistema.printoverse.store --correo tu@correo.com

Solo usa la biblioteca estandar de Python: no hay que instalar nada. Por eso
tampoco importa nada de servidor.app (no necesita FastAPI en el computador de
quien lo corre).
"""

import argparse
import getpass
import json
import re
import sys
import urllib.error
import urllib.request

PERFIL_A_IMPORTAR = "AD5M Casa"
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")

# nombre en perfiles.json -> nombre en la API
CAMPOS_PERFIL = {
    "precioKwh": "precio_kwh",
    "consumoWatts": "consumo_watts",
    "desgasteMaquina": "vida_maquina_h",
    "precioRepuestos": "precio_repuestos",
    "margenError": "margen_error",
}


class ErrorImportacion(Exception):
    """Algo del archivo o de los datos esta mal; el mensaje ya va en espanol."""


class ErrorHTTP(Exception):
    """El servidor contesto con error (o no contesto: estado 0)."""

    def __init__(self, estado: int, detalle: str):
        super().__init__(detalle)
        self.estado = estado
        self.detalle = detalle


class ClienteHTTP:
    """Lo minimo para hablar con la API: post, get y el token de la sesion.

    Es una clase aparte (y no llamadas sueltas a urllib) para que las pruebas
    le pongan un servidor falso con la misma forma.
    """

    def __init__(self, url: str):
        self.url = url.rstrip("/")
        self.token = None

    def _pedir(self, metodo: str, ruta: str, cuerpo=None):
        datos = json.dumps(cuerpo).encode("utf-8") if cuerpo is not None else None
        # User-Agent propio: algunos proxies bloquean el de "Python-urllib".
        cabeceras = {"Content-Type": "application/json", "User-Agent": "3d-organizer-importador"}
        if self.token:
            cabeceras["Authorization"] = f"Bearer {self.token}"
        peticion = urllib.request.Request(self.url + ruta, data=datos, headers=cabeceras, method=metodo)
        try:
            with urllib.request.urlopen(peticion, timeout=30) as respuesta:
                return json.loads(respuesta.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise ErrorHTTP(e.code, _detalle(e.read()))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ErrorHTTP(0, f"No se pudo conectar con {self.url}: {e}")

    def post(self, ruta: str, cuerpo):
        return self._pedir("POST", ruta, cuerpo)

    def get(self, ruta: str):
        return self._pedir("GET", ruta)


def _detalle(cuerpo: bytes) -> str:
    # FastAPI manda {"detail": "texto"} o, en un 422, {"detail": [{"loc":..., "msg":...}]}.
    try:
        detalle = json.loads(cuerpo.decode("utf-8")).get("detail")
    except (ValueError, AttributeError):
        return cuerpo.decode("utf-8", "replace")[:200]
    if isinstance(detalle, list):
        return "; ".join(f"{'.'.join(str(x) for x in d.get('loc', [])[1:])}: {d.get('msg')}"
                         for d in detalle if isinstance(d, dict))
    return str(detalle)


def _numero(texto, campo: str, vacio):
    """Texto de perfiles.json -> numero. Vacio da `vacio` (0 o None)."""
    if isinstance(texto, bool):
        raise ErrorImportacion(f"{campo}: no es un número ({texto!r})")
    if isinstance(texto, (int, float)):
        return float(texto)
    limpio = str(texto if texto is not None else "").strip()
    if not limpio:
        return vacio
    try:
        return float(limpio)
    except ValueError:
        raise ErrorImportacion(f"{campo}: no es un número ({limpio!r})")


def _clave(marca, tipo, color) -> tuple:
    # Misma regla para decidir si dos filamentos son el mismo, vengan de donde
    # vengan: sin mayusculas ni espacios de mas.
    return tuple(str(x).strip().lower() for x in (marca, tipo, color))


def _perfil_a_api(nombre: str, perfil: dict) -> dict:
    cuerpo = {"nombre": nombre}
    for origen, destino in CAMPOS_PERFIL.items():
        # Vacio -> 0. Si vida_maquina_h queda en 0 el servidor lo rechaza (es un
        # divisor) y el mensaje lo dice; mejor eso que inventar un valor.
        cuerpo[destino] = _numero(perfil.get(origen), origen, 0.0)
    cuerpo["precio_dolar"] = _numero(perfil.get("precioDolar"), "precioDolar", None)
    return cuerpo


def _filamento_a_api(f: dict) -> dict:
    cuerpo = {
        "marca": str(f.get("marca", "")).strip(), "tipo": str(f.get("tipo", "")).strip(),
        "color": str(f.get("color", "")).strip(),
        "precio_kg": _numero(f.get("precio"), f"precio de {f.get('marca')} {f.get('color')}", 0.0),
        "moneda": f.get("moneda"),
    }
    # Algunos filamentos traen 'transparente' en vez de un color: el servidor solo
    # acepta #RRGGBB, asi que lo que no lo sea se deja sin color en vez de fallar.
    if isinstance(f.get("hex"), str) and HEX.match(f["hex"]):
        cuerpo["hex"] = f["hex"]
    return cuerpo


def importar(http, correo: str, clave: str, datos: dict) -> tuple[int, int]:
    """Importa y devuelve (perfiles, filamentos) = creados + ya existentes.

    Todo el archivo se revisa antes de entrar al servidor, para que un dato
    malo no deje la importacion a medias.
    """
    perfiles_json = datos.get("profiles") or {}
    if PERFIL_A_IMPORTAR not in perfiles_json:
        raise ErrorImportacion(
            f'En el archivo no hay un perfil llamado "{PERFIL_A_IMPORTAR}". '
            f"Perfiles que hay: {', '.join(perfiles_json) or 'ninguno'}.")
    perfil = _perfil_a_api(PERFIL_A_IMPORTAR, perfiles_json[PERFIL_A_IMPORTAR])
    filamentos = [_filamento_a_api(f) for f in datos.get("filamentos") or []]

    http.token = http.post("/api/acceso", {"correo": correo, "clave": clave})["token"]

    # Perfil: se compara por nombre (es unico en el servidor).
    if not any(p["nombre"] == perfil["nombre"] for p in http.get("/api/perfiles")):
        http.post("/api/perfiles", perfil)

    # Filamentos: misma marca, tipo y color es el mismo; tambien dentro del archivo.
    vistos = {_clave(f["marca"], f["tipo"], f["color"]) for f in http.get("/api/filamentos")}
    for f in filamentos:
        clave_f = _clave(f["marca"], f["tipo"], f["color"])
        if clave_f not in vistos:
            http.post("/api/filamentos", f)
            vistos.add(clave_f)
    # Los que ya estaban cuentan igual: "Listo" dice cuantos quedan en el sistema
    # de lo que traia el archivo.
    cuantos = len({_clave(f["marca"], f["tipo"], f["color"]) for f in filamentos})
    return 1, cuantos


def _plural(n: int, singular: str, plural: str) -> str:
    return f"{n} {singular if n == 1 else plural}"


def principal(argv=None, http=None, pedir_clave=getpass.getpass) -> int:
    ap = argparse.ArgumentParser(description="Copia el perfil y los filamentos de perfiles.json al sistema.")
    ap.add_argument("--perfiles", required=True, help="ruta del perfiles.json de la calculadora")
    ap.add_argument("--url", required=True, help="direccion del sistema, ej. https://sistema.printoverse.store")
    ap.add_argument("--correo", required=True, help="el correo con el que entras al sistema")
    args = ap.parse_args(argv)

    try:
        with open(args.perfiles, encoding="utf-8") as f:
            datos = json.load(f)
    except OSError as e:
        print(f"No pude leer {args.perfiles}: {e.strerror or e}", file=sys.stderr)
        return 1
    except ValueError as e:
        print(f"{args.perfiles} no es un JSON válido: {e}", file=sys.stderr)
        return 1

    # La clave se pide por teclado (no se escribe en pantalla ni queda en el
    # historial de la terminal).
    clave = pedir_clave("Contraseña: ")
    try:
        perfiles, filamentos = importar(http or ClienteHTTP(args.url), args.correo, clave, datos)
    except ErrorImportacion as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except ErrorHTTP as e:
        print(f"Error del servidor ({e.estado or 'sin conexión'}): {e.detalle}", file=sys.stderr)
        return 1

    print(f"Listo: {_plural(perfiles, 'perfil', 'perfiles')}, {_plural(filamentos, 'filamento', 'filamentos')}")
    return 0


if __name__ == "__main__":
    sys.exit(principal())
