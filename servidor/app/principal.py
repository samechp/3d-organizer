"""
principal.py - Crea la app FastAPI y monta las rutas.

gunicorn la carga como 'servidor.app.principal:app'.
"""

from fastapi import FastAPI, HTTPException

from . import acceso, base


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

    @app.get("/health")
    def health():
        # Contesta ok solo si la base responde: nginx o un monitor pueden usarlo
        # para saber que el servicio sirve de verdad, no solo que el proceso vive.
        try:
            base.comprobar(motor_sistema)
        except Exception:
            raise HTTPException(status_code=503, detail="La base de datos no responde")
        return {"ok": True}

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
