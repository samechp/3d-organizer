"""
acceso.py - Quien puede entrar: solo el correo de SISTEMA_CORREO_PERMITIDO.

La clave no se guarda aqui: se valida contra la tabla usuarios de PrintoVerse
(solo lectura). Este servicio solo anade las sesiones (en su propia base) y el
limite de intentos.

Dos formas de presentar la sesion:
  - 'Authorization: Bearer <token>'  -> la app del iPhone.
  - cookie 'sesion'                  -> la web. Como el navegador la manda sola,
    las peticiones que cambian datos exigen ademas 'X-Sistema: 1' (CSRF).
"""

import hashlib
import hmac
import os
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import delete, func, select

from . import base

router = APIRouter()

MENSAJE_FALLO = "Correo o contraseña incorrectos"
DURACION_SESION = timedelta(days=180)
MAX_FALLOS = 5
VENTANA_FALLOS = timedelta(minutes=15)

# Mismos parametros que la tienda (n=2^15, ~100 ms por intento).
_N, _R, _P = 1 << 15, 8, 1


def verificar_clave(clave: str, guardado: str) -> bool:
    """Compara la clave con la huella 'scrypt$N$r$p$sal$hash' de PrintoVerse.

    Copia de usuarios.verificar() de la tienda (no se importa: son proyectos
    separados). Los parametros se leen de la propia huella, asi sirve aunque
    la tienda cambie su N algun dia.
    """
    try:
        alg, n, r, p, sal, esperado = str(guardado).split("$")
        if alg != "scrypt":
            return False
        # scrypt pide 128*n*r bytes y OpenSSL limita a 32 MB por defecto; sin
        # este maxmem explicito falla con "memory limit exceeded".
        h = hashlib.scrypt(clave.encode("utf-8"), salt=bytes.fromhex(sal),
                           n=int(n), r=int(r), p=int(p), dklen=len(esperado) // 2,
                           maxmem=128 * int(n) * int(r) * 2)
        # compare_digest y no '==': la comparacion normal se corta en el primer
        # byte distinto y ese tiempo es medible.
        return hmac.compare_digest(h.hex(), esperado)
    except Exception:
        return False


def cifrar_clave(clave: str) -> str:
    """Huella scrypt en el mismo formato que la tienda, para las cuentas propias."""
    sal = secrets.token_bytes(16)
    h = hashlib.scrypt(clave.encode("utf-8"), salt=sal, n=_N, r=_R, p=_P,
                       dklen=32, maxmem=128 * _N * _R * 2)
    return f"scrypt${_N}${_R}${_P}${sal.hex()}${h.hex()}"


def _huella_falsa() -> str:
    return cifrar_clave(secrets.token_urlsafe(16))


# Se calcula una sola vez al importar, con los parametros reales. Cuando el
# correo no es el permitido (o no existe) se verifica contra esta: asi la
# respuesta tarda lo mismo que con un correo valido y no se puede averiguar
# cual es el correo permitido midiendo tiempos.
HUELLA_FALSA = _huella_falsa()


def _ahora() -> datetime:
    # UTC sin zona, calculado aqui y no con now() de MySQL: asi todas las
    # fechas de sesiones e intentos se comparan en la misma hora.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _normalizar(correo: str) -> str:
    return str(correo or "").strip().lower()


def _permitido() -> str:
    # Se lee en cada peticion; si falta, queda "" y no coincide con ningun
    # correo (el servicio se cierra en vez de abrirse a todos).
    return _normalizar(os.environ.get("SISTEMA_CORREO_PERMITIDO"))


def _huella_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def ip_cliente(request: Request) -> str:
    # El servicio solo escucha en un socket unix detras de nginx, que fija
    # X-Real-IP con la IP real y descarta la que mande el cliente. Por eso es
    # seguro fiarse de ella: nadie puede llegar al servicio sin pasar por nginx.
    # Sin la cabecera (pruebas, uso local) se usa la IP de la conexion.
    ip = request.headers.get("x-real-ip") or (request.client.host if request.client else "")
    return ip.strip()[:45]  # 45 = ancho de la columna (IPv6 en texto)


class Credenciales(BaseModel):
    # Con tope de largo para no procesar cuerpos absurdos.
    correo: str = Field(max_length=190)
    clave: str = Field(max_length=256)


@router.post("/api/acceso")
def acceso(datos: Credenciales, request: Request, response: Response):
    motor = request.app.state.motor_sistema
    ip = ip_cliente(request)
    ahora = _ahora()
    corte = ahora - VENTANA_FALLOS

    with motor.begin() as con:
        # Limpieza oportunista: los fallos de mas de 15 min ya no cuentan y las
        # sesiones vencidas ya no sirven; asi las tablas no crecen sin cron.
        con.execute(delete(base.intentos).where(base.intentos.c.momento < corte))
        con.execute(delete(base.sesiones).where(base.sesiones.c.expira < ahora))
        fallos = con.execute(
            select(func.count()).select_from(base.intentos).where(
                base.intentos.c.ip == ip, base.intentos.c.momento >= corte)
        ).scalar()

    if fallos >= MAX_FALLOS:
        # Antes de mirar la clave: una IP bloqueada no debe poder seguir
        # probando (ni gastar el scrypt del servidor).
        raise HTTPException(status_code=429, detail="Demasiados intentos. Prueba de nuevo en 15 minutos")

    correo = _normalizar(datos.correo)
    fila = None
    if correo and correo == _permitido():
        with request.app.state.motor_usuarios.connect() as con:
            fila = con.execute(
                base.usuarios_tienda.select().where(base.usuarios_tienda.c.correo == correo)
            ).first()
        cuenta_ok = fila is not None and fila.activo == 1 and fila.debe_cambiar == 0
    else:
        with motor.connect() as con:
            fila = con.execute(
                base.usuarios_sistema.select().where(base.usuarios_sistema.c.correo == correo)
            ).first()
        cuenta_ok = fila is not None

    # Siempre se corre scrypt, haya cuenta o no (ver HUELLA_FALSA).
    clave_ok = verificar_clave(datos.clave, fila.clave_hash if fila else HUELLA_FALSA)

    if not (clave_ok and cuenta_ok):
        with motor.begin() as con:
            con.execute(base.intentos.insert().values(ip=ip, momento=ahora))
        # Mismo mensaje para todo: no se revela si el correo existe, si la
        # cuenta esta inactiva o si solo fallo la clave.
        raise HTTPException(status_code=401, detail=MENSAJE_FALLO)

    token = secrets.token_urlsafe(36)  # 36 bytes -> 48 caracteres
    with motor.begin() as con:
        con.execute(base.sesiones.insert().values(
            token_hash=_huella_token(token), correo=correo,
            creada=ahora, expira=ahora + DURACION_SESION))
    response.set_cookie(
        "sesion", token, max_age=int(DURACION_SESION.total_seconds()),
        httponly=True, secure=True, samesite="strict")
    return {"token": token, "correo": correo, "dueno": correo == _permitido()}


def _token_de(request: Request):
    """(token, vino_por_cookie). Bearer manda sobre la cookie."""
    autorizacion = request.headers.get("authorization", "")
    if autorizacion[:7].lower() == "bearer " and autorizacion[7:].strip():
        return autorizacion[7:].strip(), False
    cookie = request.cookies.get("sesion")
    if cookie:
        return cookie, True
    return None, False


def _exigir_x_sistema(request: Request, por_cookie: bool):
    # Solo la cookie viaja sola en una peticion de otra pagina; un Bearer lo
    # tiene que poner a mano quien ya conoce el token, asi que no necesita esto.
    if por_cookie and request.method in ("POST", "PATCH", "PUT", "DELETE"):
        if request.headers.get("x-sistema") != "1":
            raise HTTPException(status_code=403, detail="Falta la cabecera X-Sistema")


def usuario_actual(request: Request) -> str:
    """Dependencia: devuelve el correo de la sesion o responde 401/403."""
    token, por_cookie = _token_de(request)
    if not token:
        raise HTTPException(status_code=401, detail="Hay que entrar")
    _exigir_x_sistema(request, por_cookie)

    with request.app.state.motor_sistema.connect() as con:
        fila = con.execute(
            select(base.sesiones).where(base.sesiones.c.token_hash == _huella_token(token))
        ).first()
        # La cuenta tiene que seguir valiendo: si cambia el correo permitido o
        # Juan borra a un ayudante, sus sesiones viejas dejan de servir.
        vigente = fila is not None and (
            fila.correo == _permitido()
            or con.execute(select(base.usuarios_sistema.c.correo).where(
                base.usuarios_sistema.c.correo == fila.correo)).first() is not None)
    if not vigente or fila.expira <= _ahora():
        raise HTTPException(status_code=401, detail="Sesión no válida o vencida")
    return fila.correo


def solo_dueno(correo: str = Depends(usuario_actual)) -> str:
    """Dependencia: solo Juan (el correo permitido) administra las cuentas."""
    if correo != _permitido():
        raise HTTPException(status_code=403, detail="Solo el dueño puede hacer esto")
    return correo


@router.post("/api/salir")
def salir(request: Request, response: Response):
    token, por_cookie = _token_de(request)
    _exigir_x_sistema(request, por_cookie)
    if token:
        with request.app.state.motor_sistema.begin() as con:
            con.execute(delete(base.sesiones).where(base.sesiones.c.token_hash == _huella_token(token)))
    response.delete_cookie("sesion", httponly=True, secure=True, samesite="strict")
    return {"ok": True}


@router.get("/api/yo")
def yo(correo: str = Depends(usuario_actual)):
    # Ruta minima protegida: la web y la app la usan para saber si la sesion
    # sigue valiendo, y las pruebas para probar la dependencia.
    return {"correo": correo, "dueno": correo == _permitido()}


# ─────────────────────────────────────────────
#  Cuentas propias (las administra solo Juan)
# ─────────────────────────────────────────────
class CuentaNueva(BaseModel):
    correo: str = Field(min_length=3, max_length=120, pattern=r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")  # solo ASCII: sin parecidos con tildes
    # Mismo minimo que la tienda: el largo es lo que cuesta romper.
    clave: str = Field(min_length=10, max_length=256)


@router.get("/api/usuarios")
def listar_usuarios(request: Request, _: str = Depends(solo_dueno)):
    with request.app.state.motor_sistema.connect() as con:
        filas = con.execute(select(base.usuarios_sistema.c.correo, base.usuarios_sistema.c.creado)
                            .order_by(base.usuarios_sistema.c.correo)).all()
    return [{"correo": f.correo, "creado": f.creado.isoformat()} for f in filas]


@router.post("/api/usuarios", status_code=201)
def crear_usuario(datos: CuentaNueva, request: Request, _: str = Depends(solo_dueno)):
    correo = _normalizar(datos.correo)
    if correo == _permitido():
        raise HTTPException(status_code=409, detail="Ese correo ya es el tuyo")
    with request.app.state.motor_sistema.begin() as con:
        if con.execute(select(base.usuarios_sistema.c.correo).where(
                base.usuarios_sistema.c.correo == correo)).first():
            raise HTTPException(status_code=409, detail="Ya existe una cuenta con ese correo")
        con.execute(base.usuarios_sistema.insert().values(
            correo=correo, clave_hash=cifrar_clave(datos.clave), creado=_ahora()))
    return {"correo": correo}


@router.delete("/api/usuarios/{correo}", status_code=204)
def borrar_usuario(correo: str, request: Request, _: str = Depends(solo_dueno)):
    correo = _normalizar(correo)
    with request.app.state.motor_sistema.begin() as con:
        borradas = con.execute(delete(base.usuarios_sistema).where(
            base.usuarios_sistema.c.correo == correo)).rowcount
        # Fuera tambien sus sesiones abiertas: el acceso se corta en ese momento.
        con.execute(delete(base.sesiones).where(base.sesiones.c.correo == correo))
    if not borradas:
        raise HTTPException(status_code=404, detail="No existe esa cuenta")
    return Response(status_code=204)
