# 3D Organizer — Plan de construcción

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sistema para llevar los pedidos grandes de Juan (tandas buenas por modelo, avance, ritmo hasta la entrega) desde el iPhone y desde `sistema.printoverse.store`, más una calculadora de piezas en el iPhone con sus perfiles copiados de la calculadora de escritorio.

**Architecture:** Un servicio FastAPI propio (`servidor/`) con base MySQL propia en el VPS de PrintoVerse, detrás del mismo nginx. Sirve la API y una web estática sin framework. El login valida contra la tabla `usuarios` de PrintoVerse en solo lectura. La app de iPhone (`ios/`, SwiftUI) habla con la misma API, guarda en cola las tandas anotadas sin señal y deja en caché los perfiles para que la calculadora funcione sin internet.

**Tech Stack:** Python (la versión que ya tiene el servidor para PrintoVerse; 3.14 en el PC), FastAPI, SQLAlchemy Core 2 (MySQL con PyMySQL en producción, SQLite en las pruebas), pytest, gunicorn + uvicorn, nginx, systemd. iOS 17+, SwiftUI, XcodeGen, GitHub Actions `macos-26` con Xcode 26 y TestFlight.

**Spec:** [docs/superpowers/specs/2026-10-23-pedidos-grandes-design.md](../specs/2026-10-23-pedidos-grandes-design.md)
**Maqueta aprobada:** https://claude.ai/artifact/5KcGFtKRC11LSiUgbu75EV. Las pantallas y textos de la app y de la web salen de ahí.

## Global Constraints

- **Todo en español:** nombres de archivo, funciones, variables, comentarios, mensajes y textos de la interfaz. La app va solo en español (`developmentLanguage: es`).
- Densidad de comentarios y tono iguales a `../printoverse_web/api/*.py`: se comenta el porqué, no el qué.
- **Repo público** `samechp/3d-organizer`. Nunca van al repo: `.env`, claves, `.p8`, `perfiles.json` ni datos reales. `.gitignore` desde el primer commit.
- **Solo entra el correo** de `SISTEMA_CORREO_PERMITIDO` (`.env` del servidor). La cuenta debe tener `activo=1` y `debe_cambiar=0` en `usuarios` de PrintoVerse.
- **No se toca** nada de `../printoverse_web` ni de `../calculadora-3d`; solo se leen.
- Bundle ID `store.printoverse.organizador`. Nombre visible "3D Organizer". `MARKETING_VERSION` 1.0 fija; el número de compilación es `github.run_number`.
- La compilación iOS solo corre si cambia `ios/**` o el workflow. Push directo a `main`.
- iOS 26 con Liquid Glass (`.glassEffect`) y, en iOS 17–25, `.ultraThinMaterial` como alternativa. Dynamic Type con estilos de texto del sistema. VoiceOver en todos los controles. Háptica de éxito al guardar una tanda. SF Symbols. Toques de 44 pt mínimo. Modo oscuro con colores semánticos.
- Color de acento `#C2410C` (texto y rellenos con blanco encima); verde de completo `#1F7A3D`.
- Zona horaria de las fechas: `America/Bogota`.
- Fórmula de la calculadora: la de `calculate()` en `../calculadora-3d/web_app/app.js` (≈ línea 714), con mano de obra, operario y preparación de máquina en 0.

## Review Focus

1. **Tanda enviada dos veces** (reintento después de un timeout, cola sin señal que se vacía dos veces): debe quedar una sola. Lo resuelve `id_cliente` único (Task 3 y Task 9).
2. **Sesión vencida mientras hay tandas en la cola:** la cola no se borra. Se pide entrar de nuevo y luego se envía (Task 9).
3. **Fecha de entrega hoy o ya pasada:** hoy cuenta como 1 día. Si ya pasó, se muestra "Entrega vencida hace N días" y no se divide por cero ni por negativos (Task 3).
4. **Probar contraseñas a lo bruto** (el repo es público y la URL se conoce): 5 fallos en 15 min desde una IP dan 429, y un correo no permitido tarda lo mismo que uno permitido (Task 2).
5. **Cantidades raras:** 0, negativos, texto o más de 100.000 en una tanda dan 422, nunca un 500. La meta de un modelo va de 1 a 1.000.000 (Task 3).

---

## Estructura de archivos

```
.gitignore
README.md                         qué es, cómo se despliega (en español, para Juan)
servidor/
  requirements.txt                fastapi, sqlalchemy>=2, pymysql, python-multipart, gunicorn, uvicorn[standard]
  requirements-pruebas.txt        -r requirements.txt, pytest, httpx
  app/__init__.py
  app/principal.py                crea la app FastAPI, monta las rutas, /health
  app/base.py                     motores (sistema y usuarios), tablas, crear_tablas()
  app/acceso.py                   verificar_clave(), login, sesiones, límite de intentos, dependencia usuario_actual
  app/pedidos.py                  rutas y lógica de pedidos, modelos y tandas
  app/calculos.py                 avance(), ritmo(), es_parecida(): lógica pura sin BD
  app/perfiles.py                 rutas de perfiles y filamentos
  app/fotos.py                    subida y lectura de fotos de modelos
  web/index.html, web/app.js, web/estilo.css
  scripts/importar_perfiles.py    copia única desde perfiles.json
  despliegue/desplegar.sh, despliegue/sistema.service, despliegue/nginx-sistema.conf, despliegue/montar.md
  pruebas/conftest.py, pruebas/test_*.py
ios/
  project.yml
  Organizador/App.swift, Organizador/Info.plist, Organizador/Assets.xcassets
  Organizador/Nucleo/Calculo.swift        fórmula pura
  Organizador/Nucleo/ColaTandas.swift     cola sin señal (pura, con un enviador inyectado)
  Organizador/Nucleo/Modelos.swift        Codable de la API
  Organizador/Nucleo/ClienteAPI.swift     URLSession + token
  Organizador/Nucleo/Llavero.swift        token en Keychain
  Organizador/Nucleo/Almacen.swift        caché en disco (perfiles, filamentos, cola)
  Organizador/Vistas/...                  una vista por pantalla de la maqueta
  Organizador/Vistas/Estilo.swift         vidrio con alternativa, color de acento
  Pruebas/main.swift                      pruebas de Calculo y ColaTandas (swiftc, como Eyescript)
.github/workflows/ios.yml
```

---

### Task 1: Esqueleto del servidor y base de datos

**Files:**
- Create: `.gitignore`, `servidor/requirements.txt`, `servidor/requirements-pruebas.txt`, `servidor/app/__init__.py`, `servidor/app/base.py`, `servidor/app/principal.py`, `servidor/pruebas/conftest.py`, `servidor/pruebas/test_base.py`

**Interfaces:**
- Produces:
  - `base.motor_sistema() -> sqlalchemy.Engine`: lee `SISTEMA_DB_URL` (ej. `mysql+pymysql://sistema:...@localhost/sistema?charset=utf8mb4`).
  - `base.motor_usuarios() -> Engine`: lee `PRINTO_USUARIOS_URL`, un usuario MySQL que solo tiene SELECT sobre `printoverse.usuarios`.
  - `base.metadata` con estas tablas:
    - `sesiones(token_hash CHAR(64) PK, correo, creada, expira)`
    - `intentos(id PK, ip, momento)`
    - `pedidos(id PK, nombre VARCHAR(120), cliente VARCHAR(120) NULL, entrega DATE NULL, nota TEXT NULL, estado ENUM-like VARCHAR(12) 'abierto'|'terminado', creado, terminado_en NULL)`
    - `modelos(id PK, pedido_id FK, nombre VARCHAR(80), meta INT, foto VARCHAR(80) NULL, orden INT)`
    - `tandas(id PK, modelo_id FK, cantidad INT, cuando DATETIME, id_cliente CHAR(36) UNIQUE, creada)`
    - `perfiles(id PK, nombre VARCHAR(80) UNIQUE, precio_kwh, consumo_watts, vida_maquina_h, precio_repuestos, margen_error, precio_dolar NULL, activo BOOL)`, con los valores numéricos en `Numeric(14,2)`
    - `filamentos(id PK, marca, tipo, color, hex NULL, precio_kg Numeric(14,2), moneda VARCHAR(3))`
  - `base.crear_tablas(motor)`: idempotente (`metadata.create_all`).
  - `principal.crear_app(motor_sistema, motor_usuarios) -> FastAPI` y `app = crear_app(base.motor_sistema(), base.motor_usuarios())` para gunicorn (`servidor.app.principal:app`).
  - Fixture `cliente` en conftest: dos SQLite en memoria (`StaticPool`), una tabla `usuarios` falsa con las columnas `correo, clave_hash, activo, debe_cambiar` y `SISTEMA_CORREO_PERMITIDO=juan@ejemplo.com`. Devuelve `fastapi.testclient.TestClient`. Fixture `cliente_con_sesion`: lo mismo, ya autenticado (lo usa Task 3 en adelante).

- [ ] **Step 1:** `.gitignore` con `.env`, `*.p8`, `perfiles.json`, `__pycache__/`, `.venv/`, `ios/*.xcodeproj`, `build/`, `.DS_Store`. Crear el venv: `python -m venv .venv` y `.venv\Scripts\pip install -r servidor\requirements-pruebas.txt`.
- [ ] **Step 2:** Escribir la prueba `test_health_responde` (`GET /health` → 200 `{"ok": true}`) y `test_crear_tablas_dos_veces_no_falla`.
- [ ] **Step 3:** Correr `.venv\Scripts\python -m pytest servidor/pruebas -q`. Esperado: FALLA (no existe `crear_app`).
- [ ] **Step 4:** Implementar `base.py` y `principal.py`. `/health` hace `SELECT 1` contra `motor_sistema`.
- [ ] **Step 5:** Correr las pruebas. Esperado: PASAN.
- [ ] **Step 6:** `git init`, primer commit `servidor: esqueleto y tablas`.

### Task 2: Acceso (solo Juan)

**Files:**
- Create: `servidor/app/acceso.py`, `servidor/pruebas/test_acceso.py`
- Modify: `servidor/app/principal.py` (montar rutas)

**Interfaces:**
- Consumes: Task 1 (`motor_usuarios`, tablas `sesiones` e `intentos`).
- Produces:
  - `verificar_clave(clave: str, guardado: str) -> bool`: copia del formato `scrypt$N$r$p$sal$hash` de `../printoverse_web/api/usuarios.py:61` (con `hmac.compare_digest` y el mismo `maxmem`). Se copia; no se importa.
  - `POST /api/acceso {correo, clave}` → 200 `{"token": "<48 chars>", "correo": ...}` y una cookie `sesion` (HttpOnly, Secure, SameSite=Strict, 180 días). Si falla → 401 `{"detail":"Correo o contraseña incorrectos"}`, siempre el mismo mensaje.
  - `POST /api/salir`: borra la sesión.
  - Dependencia `usuario_actual(request) -> str`: acepta `Authorization: Bearer <token>` (iPhone) o la cookie `sesion` (web). Busca el sha256 del token en `sesiones` y revisa que no haya vencido. Si no → 401.
  - Peticiones con cookie que cambian datos (POST, PATCH, PUT, DELETE) exigen la cabecera `X-Sistema: 1`, contra CSRF. La web la manda siempre.

- [ ] **Step 1: Pruebas** en `test_acceso.py`:
  - `test_entra_juan`: clave correcta → 200 y un token que sirve en `GET /api/pedidos`.
  - `test_correo_no_permitido_aunque_exista`: otro usuario activo con clave correcta → 401.
  - `test_cuenta_inactiva` y `test_debe_cambiar_clave` → 401.
  - `test_clave_mala` → 401 con el mismo texto que los demás casos.
  - `test_cinco_fallos_bloquean`: el 6.º intento desde la misma IP en 15 min da 429, aunque la clave sea buena.
  - `test_sin_token_401` en `GET /api/pedidos`.
  - `test_cookie_sin_cabecera_x_sistema_403` en un POST.
  - `test_salir_invalida_token`.
  - Para el usuario de prueba, la huella se genera con un `cifrar()` auxiliar de la prueba (scrypt con n=2^14, para que la prueba sea rápida).
- [ ] **Step 2:** Correr. Esperado: FALLAN.
- [ ] **Step 3:** Implementar `acceso.py`. Si el correo no es el permitido o no existe, igual se corre `verificar_clave` contra una huella falsa, para que tarde lo mismo. En la BD se guarda solo `sha256(token)`, nunca el token.
- [ ] **Step 4:** Correr. Esperado: PASAN.
- [ ] **Step 5:** Commit `servidor: acceso solo para el correo permitido`.

### Task 3: Pedidos, modelos y tandas

**Files:**
- Create: `servidor/app/calculos.py`, `servidor/app/pedidos.py`, `servidor/pruebas/test_calculos.py`, `servidor/pruebas/test_pedidos.py`
- Modify: `servidor/app/principal.py`

**Interfaces:**
- Consumes: `usuario_actual` (Task 2), tablas (Task 1).
- Produces (los usan Task 5 y Tasks 8 y 9; los nombres JSON son exactamente estos):
  - `calculos.avance(modelos: list[tuple[int, int]]) -> dict`: recibe `(hechas, meta)` y devuelve `{"hechas_total", "meta_total", "contadas", "faltan", "porcentaje"}`. `contadas = Σ min(hechas, meta)`, `faltan = meta_total − contadas`, `porcentaje = floor(contadas*100/meta_total)`.
  - `calculos.ritmo(faltan: int, entrega: date | None, hoy: date) -> dict | None`: devuelve `None` sin fecha. Si no: `dias = (entrega − hoy).days + 1`. Con `dias ≥ 1` → `{"dias": dias, "por_dia": ceil(faltan/dias), "vencido": False}`. Con `dias < 1` → `{"dias": dias, "por_dia": None, "vencido": True, "vencido_hace": 1 − dias}`. Con `faltan == 0` → `{"completo": True}`.
  - `calculos.es_parecida(nueva_cant, nueva_cuando, previa_cant, previa_cuando, ventana=timedelta(hours=3)) -> bool`: misma cantidad y `|Δt| ≤ ventana`.
  - Rutas (todas con `usuario_actual`):
    - `GET /api/pedidos?estado=abierto|terminado` → `[{id, nombre, cliente, entrega, estado, num_modelos, avance, ritmo}]`
    - `POST /api/pedidos {nombre, cliente?, entrega?, nota?, modelos: [{nombre, meta}]}` → 201 con el detalle.
    - `GET /api/pedidos/{id}` → `{..., modelos: [{id, nombre, meta, hechas, foto_url, completo, de_mas, faltan}], avance, ritmo, ultimas_tandas: [5 más recientes]}`
    - `PATCH /api/pedidos/{id} {nombre?, cliente?, entrega?, nota?, estado?}`
    - `POST /api/pedidos/{id}/modelos {nombre, meta}`, `PATCH /api/modelos/{id}`, `DELETE /api/modelos/{id}`. El DELETE da 409 si el modelo tiene tandas.
    - `GET /api/pedidos/{id}/tandas?modelo_id=` → `[{id, modelo_id, modelo, cantidad, cuando, id_cliente}]`, de la más nueva a la más vieja.
    - `POST /api/tandas {modelo_id, cantidad, cuando?, id_cliente, forzar=false}`. Si no llega `cuando`, se usa la hora del servidor en Bogotá. Si `id_cliente` ya existe → 200 con la tanda que ya estaba (idempotente). Si hay una parecida del mismo modelo y no viene `forzar` → 409 `{"parecida": {id, cantidad, cuando, hace_minutos}}`. Si no → 201.
    - `PATCH /api/tandas/{id} {cantidad?, cuando?}`, `DELETE /api/tandas/{id}` → 204.
  - Validación (Pydantic): cantidad 1–100000, meta 1–1000000, nombre de 1 a 120 caracteres, modelos de 1 a 50 por pedido.

- [ ] **Step 1: Pruebas puras** en `test_calculos.py`, con los números de la maqueta:
  - `avance([(812,1000),(645,1000),(1012,1000),(380,1000)])` → `contadas=2837, faltan=1163, porcentaje=70`. Con floor de 70,925 sale 70; la maqueta mostraba 71 redondeando, y se usa floor para no mostrar 100 % antes de tiempo.
  - `ritmo(1163, date(2026,11,20), date(2026,10,23))` → `{"dias":29,"por_dia":41,"vencido":False}`.
  - `ritmo(22, date(2026,10,23), date(2026,10,23))` → `dias=1, por_dia=22`.
  - `ritmo(5, date(2026,10,20), date(2026,10,23))` → `vencido=True, vencido_hace=3`.
  - `ritmo(0, …)` → `{"completo": True}`. `ritmo(10, None, …)` → `None`.
  - `es_parecida`: 50 a las 15:02 contra 50 a las 15:42 → True. Contra 50 a las 19:00 → False. Contra 49 a las 15:42 → False.
- [ ] **Step 2: Pruebas de rutas** en `test_pedidos.py`:
  - `test_crear_y_ver_detalle`
  - `test_tanda_suma_al_modelo`
  - `test_pasarse_de_meta_se_permite` (1.012/1.000 → `completo=True, de_mas=12`)
  - `test_tanda_parecida_da_409_y_con_forzar_201`
  - `test_mismo_id_cliente_dos_veces_una_sola_tanda`
  - `test_cantidad_invalida_422` (0, −3, "abc", 100001)
  - `test_borrar_y_editar_tanda`
  - `test_borrar_modelo_con_tandas_409`
  - `test_terminados_no_salen_en_abiertos`
- [ ] **Step 3:** Correr. Esperado: FALLAN.
- [ ] **Step 4:** Implementar `calculos.py` y luego `pedidos.py`. Las sumas de `hechas` se hacen en SQL (`GROUP BY modelo_id`).
- [ ] **Step 5:** Correr. Esperado: PASAN.
- [ ] **Step 6:** Commit `servidor: pedidos, modelos y tandas`.

### Task 4: Perfiles, filamentos, fotos e importación

**Files:**
- Create: `servidor/app/perfiles.py`, `servidor/app/fotos.py`, `servidor/scripts/importar_perfiles.py`, `servidor/pruebas/test_perfiles.py`, `servidor/pruebas/test_importar.py`
- Modify: `servidor/app/principal.py`

**Interfaces:**
- Produces:
  - `GET /api/perfiles` → `[{id, nombre, precio_kwh, consumo_watts, vida_maquina_h, precio_repuestos, margen_error, precio_dolar, activo}]`. También `POST`, `PATCH /{id}` y `DELETE /{id}`. No se puede borrar el último perfil (409). Solo hay un `activo`.
  - `GET /api/filamentos` → `[{id, marca, tipo, color, hex, precio_kg, moneda}]`. También `POST`, `PATCH /{id}` y `DELETE /{id}`.
  - `PUT /api/modelos/{id}/foto` (multipart `foto`): acepta JPEG o PNG por sus bytes mágicos, hasta 3 MB. Se guarda en `SISTEMA_FOTOS` (por defecto `/opt/sistema/fotos`) con el nombre `sha256.ext`. `GET /api/fotos/{nombre}` exige sesión y solo acepta nombres del tipo `^[0-9a-f]{64}\.(jpg|png)$`.
  - `scripts/importar_perfiles.py --perfiles <ruta a perfiles.json> --url https://sistema.printoverse.store --correo <correo>`: pide la contraseña con `getpass`, entra y hace los POST de **solo** `profiles["AD5M Casa"]` y la lista `filamentos`. Ignora `pieces`, `projects`, `megaProjects` y `empresas`. Es idempotente: no duplica un filamento con la misma marca, tipo y color, ni un perfil con el mismo nombre. Los textos numéricos vacíos de `perfiles.json` (ej. `precioKg: ''`) pasan a `null` o `0`.
  - Correspondencia de campos: `precioKwh→precio_kwh`, `consumoWatts→consumo_watts`, `desgasteMaquina→vida_maquina_h`, `precioRepuestos→precio_repuestos`, `margenError→margen_error`, `precioDolar→precio_dolar`, `precio→precio_kg`.

- [ ] **Step 1:** Pruebas:
  - `test_perfiles_crud`
  - `test_no_borrar_ultimo_perfil`
  - `test_foto_png_valida_y_lectura_con_sesion`
  - `test_foto_que_no_es_imagen_415`
  - `test_nombre_de_foto_con_puntos_404` (`../.env`)
  - `test_importar_mapea_ad5m_casa`: un `perfiles.json` de prueba hecho dentro de la prueba con `precioKwh:'800'`, … → perfil con `precio_kwh=800`. Usa un cliente HTTP falso inyectado.
  - `test_importar_dos_veces_no_duplica`
- [ ] **Step 2:** Correr. Esperado: FALLAN.
- [ ] **Step 3:** Implementar.
- [ ] **Step 4:** Correr. Esperado: PASAN.
- [ ] **Step 5:** Commit `servidor: perfiles, filamentos, fotos e importador`.

### Task 5: Página web

**Files:**
- Create: `servidor/web/index.html`, `servidor/web/app.js`, `servidor/web/estilo.css`

**Interfaces:**
- Consumes: todas las rutas de Tasks 2–4. Siempre usa `credentials: 'same-origin'` y la cabecera `X-Sistema: 1`.
- Pantallas, como el artboard "Web" de la maqueta:
  - Entrar (correo y contraseña).
  - Columna de pedidos abiertos, más "Ver terminados".
  - Detalle: avance, ritmo, tarjetas por modelo.
  - Formulario "Anotar tanda": modelo, buenas y fecha y hora con `datetime-local`, que por defecto es ahora. Si la API da 409, muestra el aviso "¿Es otra tanda?" con "Sí, guardar" (reenvía con `forzar`) y "No, ya estaba".
  - Historial con Editar (en línea) y Borrar (con `confirm`).
  - Nuevo pedido y Editar pedido (diálogo), y Marcar terminado.
- Sin framework ni compilación. JS clásico en español. Sin calculadora.

- [ ] **Step 1:** Implementar la página.
- [ ] **Step 2:** Verificar en local. En una terminal, `set SISTEMA_DB_URL=sqlite:///local.db` y un `PRINTO_USUARIOS_URL` de SQLite con un usuario de prueba creado con un comando de una línea. Luego `.venv\Scripts\uvicorn servidor.app.principal:app --reload`. `principal.py` sirve `web/` como estáticos **solo** si `SISTEMA_SERVIR_WEB=1`; en producción lo sirve nginx.
- [ ] **Step 3:** Recorrer en el navegador: entrar, crear el pedido de 4 modelos, anotar 50, anotar 50 otra vez (debe salir el aviso), confirmar, editar y borrar una tanda, y ver que la página se ve bien a 390 px de ancho.
- [ ] **Step 4:** Commit `web: panel de pedidos grandes`.

### Task 6: Despliegue en el VPS

**Files:**
- Create: `servidor/despliegue/desplegar.sh`, `servidor/despliegue/sistema.service`, `servidor/despliegue/nginx-sistema.conf`, `servidor/despliegue/montar.md`, `README.md`

**Interfaces:**
- En el servidor: `/opt/sistema/app` (clon del repo), `/opt/sistema/venv`, `/opt/sistema/publico` (copia de `servidor/web/`), `/opt/sistema/fotos`, `/opt/sistema/.env` (permisos 600, dueño `sistema`), usuario de sistema `sistema` y socket `/run/sistema/gunicorn.sock`.
- `sistema.service`: el mismo encierro que `../printoverse_web/despliegue/printoverse.service`, con `ReadWritePaths=/run/sistema /opt/sistema/fotos`, 2 workers y `servidor.app.principal:app`.
- `nginx-sistema.conf`: un bloque `server` para `sistema.printoverse.store`, en su **propio** archivo `/etc/nginx/sites-available/sistema`, sin tocar el de PrintoVerse. Incluye las cabeceras `noindex` y `no-referrer`, `client_max_body_size 4M`, `/api/` y `/health` hacia el socket, y lo demás `try_files $uri /index.html`.
- `desplegar.sh`: el patrón de `../printoverse_web/despliegue/desplegar.sh` (se copia a `/tmp` antes de correr, `git reset`, `pip install`, publica `web/`, `nginx -t` antes de recargar, `/health` y vuelta atrás si falla), recortado a lo que hace falta aquí.

- [ ] **Step 1: Paso de Juan (DNS).** Crear el registro `A` de `sistema` hacia `149.56.129.121` donde esté el dominio `printoverse.store`. Dárselo explicado paso a paso según su proveedor (preguntarle cuál es).
- [ ] **Step 2: GitHub (lo hace Claude, no Juan).** Primero `gh auth setup-git`. Luego, desde la carpeta, `gh repo create samechp/3d-organizer --public --source . --push`.
- [ ] **Step 3:** Por SSH (`ssh -i ~/.ssh/ovh_postiz ubuntu@149.56.129.121`), seguir `montar.md`:
  - usuario `sistema` y carpetas;
  - `CREATE DATABASE sistema CHARACTER SET utf8mb4`;
  - usuario MySQL `sistema` con todos los permisos sobre `sistema.*`;
  - usuario MySQL `sistema_lee` con `GRANT SELECT ON <base de printoverse>.usuarios`. El nombre de la base se lee de `PRINTO_DB_NAME` en `/opt/printoverse/.env` en el servidor, sin copiarlo a ningún lado;
  - `.env` con `SISTEMA_DB_URL`, `PRINTO_USUARIOS_URL`, `SISTEMA_CORREO_PERMITIDO` (el correo de Juan) y `SISTEMA_FOTOS`. Las contraseñas se generan en el servidor con `openssl rand -base64 32` y no salen de ahí;
  - `certbot --nginx -d sistema.printoverse.store`.
- [ ] **Step 4:** Correr `bash /opt/sistema/app/servidor/despliegue/desplegar.sh`. Esperado: `curl -s https://sistema.printoverse.store/health` → `{"ok":true}`.
- [ ] **Step 5:** Confirmar que no se rompió nada: `https://printoverse.store` y `https://dashboard.printoverse.store` siguen respondiendo 200.
- [ ] **Step 6:** Importar los perfiles: `.venv\Scripts\python servidor\scripts\importar_perfiles.py --perfiles ..\calculadora-3d\perfiles.json --url https://sistema.printoverse.store --correo <correo de Juan>`. Juan escribe su contraseña. Esperado: "1 perfil, 25 filamentos".
- [ ] **Step 7:** Commit `despliegue: sistema.printoverse.store` y push.

### Task 7: Calculadora pura en Swift

**Files:**
- Create: `ios/Organizador/Nucleo/Calculo.swift`, `ios/Pruebas/main.swift`

**Interfaces:**
- Produces:
  - `struct Perfil: Codable { precioKwh, consumoWatts, vidaMaquinaH, precioRepuestos, margenError: Double }`
  - `struct EntradaCalculo { minutos: Double; filamentos: [(gramos: Double, precioKg: Double)]; partes: [(minutos: Double, filamentos: [(gramos: Double, precioKg: Double)])]; unidadesCama: Double; margenGanancia: Double; insumos: Double; insumosACobrar: Double?; redondeo: Redondeo }`
  - `enum Redondeo { case ninguno, a500, a1000, a5000 }`: se aplica con `ceil` al precio por pieza, igual que `applyRedondeo`.
  - `func calcular(_ e: EntradaCalculo, perfil: Perfil) -> ResultadoCalculo`, con los campos `costoBaseCama, cobrarCama, precioPieza, costoPieza, gananciaPieza, horasConMargen, gramosConMargen, gramos`.
  - La ganancia usa el precio ya redondeado: `precioPieza − costoPieza − insumos/u`. Si `insumosACobrar` es nil o ≤ 0, se cobra `insumos`.

- [ ] **Step 1:** Pruebas en `Pruebas/main.swift` con un perfil inventado (800, 300, 4000, 120000, 20) y PLA a 80000 (el repo es público: nada de datos reales). Son valores calculados con la fórmula de escritorio, con tolerancia 0,01:
  - 150 min, 60 g, 20 por cama, ×3, sin redondeo → `costoBaseCama 6570`, `cobrarCama 19710`, `precioPieza 985.5`, `costoPieza 328.5`, `gananciaPieza 657`, `horasConMargen 3`, `gramosConMargen 72`.
  - Lo mismo con insumos 2000 y a cobrar 3000 → `cobrarCama 22710`, `gananciaPieza 707`.
  - Insumos 2000 sin "a cobrar" → `cobrarCama 21710`.
  - Con una parte extra de 60 min y 20 g → `costoBaseCama 8814`, `precioPieza 1322.1`, `horasConMargen 4.2`.
  - Redondeo `.a500` del primer caso → `precioPieza 1000`.
- [ ] **Step 2:** Correr `swiftc ios/Organizador/Nucleo/Calculo.swift ios/Pruebas/main.swift -o pruebas && ./pruebas` (en CI, Task 8). En Windows no hay swiftc: la primera corrida es la de CI.
- [ ] **Step 3:** Implementar `Calculo.swift`.
- [ ] **Step 4:** Commit `ios: fórmula de la calculadora` (va junto con Task 8 en el mismo push, para compilar una sola vez).

### Task 8: Proyecto iOS, compilación, acceso y API

**Files:**
- Create: `ios/project.yml`, `ios/Organizador/App.swift`, `ios/Organizador/Info.plist` (lo genera XcodeGen), `Assets.xcassets` (AppIcon 1024 con el ícono de la caja de la maqueta: blanco sobre `#C2410C`), `Nucleo/Modelos.swift`, `Nucleo/ClienteAPI.swift`, `Nucleo/Llavero.swift`, `Vistas/Estilo.swift`, `Vistas/EntrarVista.swift`, `Vistas/RaizVista.swift`, `.github/workflows/ios.yml`

**Interfaces:**
- Consumes: la API de Tasks 2–4 en `https://sistema.printoverse.store`.
- Produces:
  - `ClienteAPI.compartido`: `entrar(correo:clave:)`, `salir()`, `pedidos(estado:)`, `pedido(id:)`, `crearPedido(_:)`, `editarPedido`, `agregarModelo`, `subirFoto(modeloId:jpeg:)`, `tandas(pedidoId:modeloId:)`, `enviarTanda(_:forzar:) throws -> ResultadoTanda` (`.guardada(Tanda)`, `.parecida(TandaParecida)`), `editarTanda`, `borrarTanda`, `perfiles()`, `filamentos()` y el CRUD de ambos. Lanza `ErrorAPI.sinSesion` cuando la respuesta es 401 y `ErrorAPI.sinConexion` cuando falla la red.
  - `Modelos.swift`: Codable con `convertFromSnakeCase` para los JSON de Task 3 y Task 4.
  - `Estilo.swift`: `extension View { func vidrio(_ forma:) }`, que usa `glassEffect` con `#available(iOS 26, *)` y si no `.background(.ultraThinMaterial, in: forma)`. `Color.acento = #C2410C`.
  - `RaizVista`: sin token muestra `EntrarVista`; con token, un `TabView` con Pedidos, Calculadora y Ajustes.
- `project.yml`: el patrón de `../Teleprompter iPhone/project.yml` con `name: Organizador`, `developmentLanguage: es`, iOS 17.0, `PRODUCT_BUNDLE_IDENTIFIER: store.printoverse.organizador`, `CFBundleDisplayName: 3D Organizer`, `CFBundleDevelopmentRegion: es`, `NSCameraUsageDescription`/`NSPhotoLibraryUsageDescription` en español para la foto del modelo, y `ITSAppUsesNonExemptEncryption: false`.
- `ios.yml`: el patrón de `../Teleprompter iPhone/.github/workflows/build.yml` con `paths: ['ios/**', '.github/workflows/ios.yml']`, `working-directory: ios`, el paso de pruebas con `swiftc Organizador/Nucleo/Calculo.swift Organizador/Nucleo/ColaTandas.swift Pruebas/main.swift` y el scheme `Organizador`.

- [ ] **Step 1: Paso de Juan (Apple).** En App Store Connect, crear la app "3D Organizer" con el bundle ID `store.printoverse.organizador`; si no aparece, primero registrarlo en developer.apple.com → Identifiers. En el repo nuevo, cargar los mismos 4 Secrets que usa Eyescript (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`): explicarle cómo con `gh secret set` desde la carpeta de Eyescript, sin que las claves pasen por el chat.
- [ ] **Step 2:** Implementar los archivos.
- [ ] **Step 3:** Push a `main`. Esperado: Actions en verde (pruebas de Task 7 pasan, sube a TestFlight). Si falla, leer el log con `gh run view --log-failed`, corregir y reintentar.
- [ ] **Step 4:** Juan instala desde TestFlight y entra con su correo. Otro correo del panel debe dar "Correo o contraseña incorrectos".

### Task 9: Pedidos, anotar tanda, cola sin señal e historial

**Files:**
- Create: `Nucleo/ColaTandas.swift`, `Nucleo/Almacen.swift`, `Vistas/PedidosVista.swift`, `Vistas/DetallePedidoVista.swift`, `Vistas/AnotarTandaVista.swift`, `Vistas/HistorialVista.swift`, `Vistas/NuevoPedidoVista.swift`
- Modify: `ios/Pruebas/main.swift`

**Interfaces:**
- Consumes: `ClienteAPI` (Task 8).
- Produces:
  - `struct TandaPendiente: Codable { idCliente: UUID; modeloId: Int; cantidad: Int; cuando: Date }`
  - `final class ColaTandas` con `init(archivo: URL, enviar: (TandaPendiente) async throws -> Void)`, `agregar(_:)`, `vaciar() async` y `pendientes: [TandaPendiente]`. Se guarda en disco con cada cambio. `vaciar` envía en orden, quita cada tanda solo cuando se envió bien y se detiene ante `sinConexion` o `sinSesion` **sin borrar nada**. Si ya hay un vaciado en curso, no arranca otro.
- Comportamiento (pantallas 1–6 de la maqueta):
  - **Anotar:** primero `enviarTanda(forzar: false)`. Si responde `.parecida`, muestra la alerta "¿Es otra tanda?" con el texto de la maqueta; "Sí, es otra: guardar" reenvía con `forzar: true`. Si responde `sinConexion`, revisa contra las últimas tandas en caché con la misma regla de 3 h, pregunta si hace falta y lo deja en la cola. Lo que entra a la cola se envía después **con `forzar: true`**, porque Juan ya decidió. Al guardar, háptica `.success`. Si quedan pendientes, una franja "1 tanda pendiente de enviar".
  - `vaciar()` corre al abrir la app, al volver a primer plano y cuando `NWPathMonitor` dice que hay red.
  - Las cantidades rápidas son las 3 últimas distintas de ese pedido.
  - En el historial, deslizar a la izquierda muestra Editar y Borrar (con confirmación).
  - Pull to refresh en Pedidos y en Detalle.
  - La foto del modelo se toma con `PhotosPicker` o con la cámara, se reduce a 800 px y se manda en JPEG con calidad 0,7.
  - Modo oscuro, Dynamic Type, VoiceOver con las etiquetas de la maqueta y el iPhone SE: revisar cada pantalla con un `#Preview` en esos modos.

- [ ] **Step 1:** Pruebas de `ColaTandas` en `Pruebas/main.swift`, con un enviador falso:
  - `pruebaColaEnviaEnOrden`
  - `pruebaColaSinConexionNoBorra`
  - `pruebaColaSinSesionNoBorra`
  - `pruebaColaSobreviveReinicio`: escribe, crea otra instancia con el mismo archivo y lee lo mismo.
  - `pruebaDosVaciadosALaVezEnvianUnaVez`
- [ ] **Step 2:** Implementar `ColaTandas`, `Almacen` y las vistas.
- [ ] **Step 3:** Push junto con Task 10, para compilar una sola vez.

### Task 10: Calculadora y ajustes

**Files:**
- Create: `Vistas/CalculadoraVista.swift`, `Vistas/AjustesVista.swift`, `Vistas/PerfilVista.swift`, `Vistas/FilamentoVista.swift`

**Interfaces:**
- Consumes: `calcular` (Task 7), `ClienteAPI` y `Almacen` (Tasks 8–9).
- Comportamiento (pantallas 7–8 de la maqueta):
  - Perfiles y filamentos se descargan al abrir la app y quedan guardados en `Almacen`. Sin red se usa la copia guardada, y la calculadora nunca queda vacía si alguna vez hubo datos.
  - Los campos son `TextField` numéricos (`.decimalPad`) con botones −/+ de 44 pt: tiempo (±15 min), gramos (±5) y unidades por cama (±1).
  - Margen de ganancia con un multiplicador ×.
  - Interruptor de varios filamentos, "+ Parte extra" (tiempo y filamentos), "+ Insumos" (costo y a cobrar) y un selector de redondeo que empieza en "Sin redondeo", como la maqueta aprobada.
  - El resultado se recalcula en vivo.
  - Ajustes: elegir el perfil activo, crear o editar perfiles, crear o editar filamentos y cerrar sesión. Si cierras sesión con tandas pendientes, avisa antes.

- [ ] **Step 1:** Implementar.
- [ ] **Step 2:** Push (Tasks 9 y 10 juntas). Esperado: Actions en verde y nueva compilación en TestFlight.
- [ ] **Step 3: Aceptación con Juan.**
  - Anotar en modo avión, volver a tener señal y comprobar que la tanda aparece una sola vez en la web.
  - Anotar dos veces lo mismo y ver el aviso.
  - En la calculadora del iPhone, meter los datos de una pieza guardada en la de escritorio (ej. "QR1": 4 h 45 min, 120 g) con el mismo margen y redondeo, y comparar que da el mismo precio.
  - Revisar la pantalla en su iPhone y, si tiene a mano, en uno con notch o en un SE.
  - Dar la puntuación HIG final sobre 10.
