"""
principal.py - Crea la app FastAPI y monta las rutas.

gunicorn la carga como 'servidor.app.principal:app'.
"""

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles

from . import acceso, base, fotos, pedidos, perfiles, productos


def crear_app(motor_sistema, motor_usuarios) -> FastAPI:
    """Arma la app con los motores que se le den.

    Recibe los motores en vez de crearlos para que las pruebas usen SQLite
    en memoria sin tocar variables de entorno.
    """
    base.crear_tablas(motor_sistema)

    app = FastAPI(title="3D Organizer")
    app.state.motor_sistema = motor_sistema
    app.state.motor_usuarios = motor_usuarios

    app.include_router(acceso.router)
    app.include_router(pedidos.router)
    app.include_router(perfiles.router)
    app.include_router(productos.router)
    app.include_router(fotos.router)

    @app.get("/health")
    def health():
        # Contesta ok solo si la base responde: nginx o un monitor pueden usarlo
        # para saber que el servicio sirve de verdad, no solo que el proceso vive.
        try:
            base.comprobar(motor_sistema)
        except Exception:
            raise HTTPException(status_code=503, detail="La base de datos no responde")
        return {"ok": True}

    # Al final, despues de todas las rutas: un mount en "/" atrapa cualquier
    # camino que no haya coincidido antes, asi que si fuera primero taparia /api.
    # Solo con SISTEMA_SERVIR_WEB=1 (uso local): en produccion lo sirve nginx.
    if os.environ.get("SISTEMA_SERVIR_WEB") == "1":
        carpeta_web = Path(__file__).resolve().parent.parent / "web"
        app.mount("/", StaticFiles(directory=carpeta_web, html=True), name="web")

    return app


def __getattr__(nombre):
    # 'app' se crea al pedirla por primera vez, no al importar. Asi las pruebas
    # (que llaman a crear_app con SQLite) pueden importar este modulo sin tener
    # SISTEMA_DB_URL, y en produccion, si falta una variable, el error sale claro
    # al arrancar gunicorn en vez de un "attribute app not found".
    if nombre == "app":
        globals()["app"] = crear_app(base.motor_sistema(), base.motor_usuarios())
        return globals()["app"]
    raise AttributeError(f"module {__name__!r} has no attribute {nombre!r}")
