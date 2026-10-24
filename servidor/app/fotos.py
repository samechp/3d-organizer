"""
fotos.py - Foto de cada modelo de un pedido y de cada producto.

Las fotos viven en una carpeta del servidor (SISTEMA_FOTOS), no en la base. Cada
archivo se llama como el hash de su contenido: la misma foto subida dos veces
ocupa un solo archivo, y como el nombre cambia si cambia la foto, el navegador
puede guardarla para siempre sin riesgo de ensenar una vieja.
"""

import hashlib
import os
import re
import tempfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select, update

from . import base, pedidos, productos
from .acceso import usuario_actual

# Todas las rutas piden sesion: las fotos de los pedidos no son publicas.
router = APIRouter(dependencies=[Depends(usuario_actual)])

MAX_BYTES = 3 * 1024 * 1024
TROZO = 64 * 1024

# Cada formato se reconoce por sus primeros bytes, nunca por el nombre ni por el
# Content-Type que declare el cliente (los dos los escribe quien sube).
FIRMAS = (
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"\xff\xd8\xff", "jpg"),
)
TIPOS = {"png": "image/png", "jpg": "image/jpeg"}
# El nombre es exactamente un sha256 en hexadecimal y una de las dos extensiones.
# fullmatch y no search: "a.png.png" o un "../" delante no pasan.
NOMBRE_VALIDO = re.compile(r"[0-9a-f]{64}\.(jpg|png)")


def carpeta_fotos() -> Path:
    # Se lee en cada peticion (no al importar) para que las pruebas la cambien.
    return Path(os.environ.get("SISTEMA_FOTOS", "/opt/sistema/fotos"))


def _extension(inicio: bytes) -> str | None:
    for firma, ext in FIRMAS:
        if inicio.startswith(firma):
            return ext
    return None


def _leer_foto(archivo) -> tuple[bytes, str]:
    """Lee el archivo subido en trozos; devuelve (bytes, extension).

    Se corta en cuanto pasa del limite: un archivo enorme no se carga entero en
    memoria, y uno que no es imagen se rechaza con el primer trozo.
    """
    partes: list[bytes] = []
    total = 0
    ext = None
    while True:
        trozo = archivo.read(TROZO)
        if not trozo:
            break
        if not partes:
            ext = _extension(trozo)
            if ext is None:
                raise HTTPException(status_code=415, detail="La foto debe ser JPEG o PNG")
        total += len(trozo)
        if total > MAX_BYTES:
            raise HTTPException(status_code=413, detail="La foto pesa más de 3 MB")
        partes.append(trozo)
    if ext is None:  # archivo vacio
        raise HTTPException(status_code=415, detail="La foto debe ser JPEG o PNG")
    return b"".join(partes), ext


def _guardar(contenido: bytes, nombre: str):
    carpeta = carpeta_fotos()
    carpeta.mkdir(parents=True, exist_ok=True)
    destino = carpeta / nombre
    if destino.exists():
        return  # mismo contenido, mismo nombre: ya esta
    # Se escribe a un temporal y se renombra: un corte a la mitad nunca deja un
    # archivo cortado con el nombre final (que se serviria roto para siempre).
    fd, temporal = tempfile.mkstemp(dir=carpeta, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(contenido)
        os.replace(temporal, destino)
    except BaseException:
        try:
            os.unlink(temporal)
        except FileNotFoundError:
            pass
        raise


@router.put("/api/modelos/{modelo_id}/foto")
def subir_foto(modelo_id: pedidos.IdRuta, foto: UploadFile, request: Request,
               correo: pedidos.Correo):
    motor = request.app.state.motor_sistema
    with motor.connect() as con:
        pedidos._modelo_o_404(con, modelo_id, correo)

    contenido, ext = _leer_foto(foto.file)
    nombre = f"{hashlib.sha256(contenido).hexdigest()}.{ext}"
    _guardar(contenido, nombre)

    with motor.begin() as con:
        # Si el modelo se borro mientras se subia, el update no toca nada y el
        # 404 sale al leerlo.
        con.execute(update(base.modelos).where(base.modelos.c.id == modelo_id).values(foto=nombre))
        return pedidos._modelo_con_hechas(con, modelo_id, correo)


@router.put("/api/productos/{producto_id}/foto")
def subir_foto_producto(producto_id: pedidos.IdRuta, foto: UploadFile, request: Request,
                        correo: pedidos.Correo):
    # Igual que la de un modelo, pero colgada del producto.
    motor = request.app.state.motor_sistema
    with motor.connect() as con:
        productos._producto_o_404(con, producto_id, correo)

    contenido, ext = _leer_foto(foto.file)
    nombre = f"{hashlib.sha256(contenido).hexdigest()}.{ext}"
    _guardar(contenido, nombre)

    with motor.begin() as con:
        con.execute(update(base.productos).where(base.productos.c.id == producto_id).values(foto=nombre))
        return productos._detalle(con, producto_id, correo)


@router.get("/api/fotos/{nombre}")
def ver_foto(nombre: str, request: Request, correo: pedidos.Correo):
    # Cualquier cosa que no sea un nombre de los que genera subir_foto es 404,
    # sin tocar el disco: asi no hay forma de salirse de la carpeta.
    if not NOMBRE_VALIDO.fullmatch(nombre):
        raise HTTPException(status_code=404, detail="No existe esa foto")
    # Solo se sirve si algun modelo o producto de quien la pide la usa: la foto
    # de otra cuenta da 404 aunque el archivo exista.
    with request.app.state.motor_sistema.connect() as con:
        suya = con.execute(
            select(base.modelos.c.id)
            .select_from(base.modelos.join(base.pedidos, base.pedidos.c.id == base.modelos.c.pedido_id))
            .where(base.modelos.c.foto == nombre, base.pedidos.c.dueno == correo).limit(1)).first()
        if suya is None:
            suya = con.execute(select(base.productos.c.id).where(
                base.productos.c.foto == nombre, base.productos.c.dueno == correo).limit(1)).first()
    if suya is None:
        raise HTTPException(status_code=404, detail="No existe esa foto")
    ruta = carpeta_fotos() / nombre
    if not ruta.is_file():
        raise HTTPException(status_code=404, detail="No existe esa foto")
    return FileResponse(
        ruta, media_type=TIPOS[nombre.rsplit(".", 1)[1]],
        # El nombre es el hash del contenido, asi que nunca cambia. 'private':
        # solo el navegador de quien tiene sesion la guarda, no un cache comun.
        headers={"Cache-Control": "private, max-age=31536000, immutable",
                 "X-Content-Type-Options": "nosniff"})
