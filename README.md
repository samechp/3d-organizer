# 3D Organizer

Herramienta privada de Juan para llevar los pedidos grandes de impresion 3D:
cuantas piezas faltan de cada modelo, a que ritmo hay que imprimir para llegar a
la fecha de entrega, y cuanto cuesta cada pieza (con la formula de la
calculadora).

## Las tres partes

| Parte | Carpeta | Que es |
|---|---|---|
| Servidor | `servidor/app/` | API en Python (FastAPI) con base de datos MariaDB. Pedidos, modelos, tandas, perfiles, filamentos y fotos. |
| Web | `servidor/web/` | La pantalla para el navegador (HTML, JS y CSS sin librerias). |
| App de iPhone | `ios/` | La app nativa (SwiftUI), con cola para anotar tandas sin señal. |

Entrar solo puede el correo que ponga `SISTEMA_CORREO_PERMITIDO` en el servidor,
con su cuenta de PrintoVerse.

## Donde vive

- Direccion: <https://sistema.printoverse.store>
- Servidor: el mismo VPS de PrintoVerse (`149.56.129.121`), en `/opt/sistema`.
  Base de datos propia (`sistema`); de la tienda solo lee la tabla `usuarios`
  para comprobar la contrasena.
- La app de iPhone se compila sola con GitHub Actions cuando cambia `ios/` y se
  sube a TestFlight.

## Como se despliega el servidor

Los cambios en `servidor/` no llegan solos: hay que subirlos a `main` y despues
correr en el VPS:

```
ssh -i ~/.ssh/ovh_postiz ubuntu@149.56.129.121 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh'
```

El guion trae `main`, instala dependencias, publica la web, crea las tablas que
falten, reinicia el servicio y comprueba que responde. Si la version nueva no
responde, vuelve sola a la anterior.

Montarlo desde cero en un servidor nuevo: `servidor/despliegue/montar.md`.

## Pruebas

```
.venv\Scripts\python -m pytest servidor\pruebas
```

## Regla de oro: los secretos nunca entran al repositorio

**Este repositorio es publico.** Nunca se suben: contraseñas, el archivo `.env`,
claves (`.p8`), el `perfiles.json` ni datos reales de pedidos o clientes. El
`.gitignore` ya excluye los mas comunes, pero la costumbre es la defensa de
verdad: si dudas, no lo subas.

Todo lo secreto vive solo en el servidor, en `/opt/sistema/.env` (permisos 600),
y las claves de la app de iPhone en los *Secrets* del repositorio de GitHub.

Mas adelante el repositorio pasara a **privado**; cuando eso ocurra, el servidor
tendra que clonar con credenciales (hoy clona por HTTPS sin ellas) y habra que
revisar este archivo y `montar.md`.
