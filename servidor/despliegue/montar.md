# Montar 3D Organizer en el VPS (una sola vez)

Guion para dejar `https://sistema.printoverse.store` funcionando. Cada bloque se
pega tal cual en la sesion SSH:

```
ssh -i ~/.ssh/ovh_postiz ubuntu@149.56.129.121
```

Reglas del guion:

- Los bloques empiezan con `set -euo pipefail`: para que un error no cierre la
  sesion SSH, guardar cada bloque como un fichero y enviarlo con
  `ssh ... 'bash -s' < bloque.sh` (o pegarlo dentro de `bash -c '...'`).
- Se sigue **en orden**. Los pasos 1 a 4 se pueden repetir sin romper nada; cada
  uno dice como.
- Las contrasenas se generan **en el servidor** y no salen de ahi: ningun
  comando las imprime ni las manda al chat. Este repositorio es publico: nada
  de esto (ni el nombre de la base de PrintoVerse) se copia a ningun fichero
  del repo.
- Esto no toca PrintoVerse: ni su base, ni su `.env`, ni su archivo de nginx.
  Solo **lee** el nombre de su base (paso 2).

Esquema del servidor al terminar:

```
/opt/sistema/app        clon del repo (rama main)
/opt/sistema/venv       Python con las dependencias
/opt/sistema/publico    copia de servidor/web/ (la que sirve nginx)
/opt/sistema/fotos      fotos de los modelos (no se borra al desplegar)
/opt/sistema/.env       claves, permisos 600, dueño 'sistema'
/run/sistema/gunicorn.sock   socket de la app (lo crea systemd)
```

## 0. Comprobaciones previas

```bash
python3 --version                  # debe ser 3.10 o mas
python3 -c 'import sys; assert sys.version_info >= (3, 10), sys.version; print("python ok")'
nginx -v
mariadb --version
certbot --version
getent hosts sistema.printoverse.store    # debe dar 149.56.129.121
sudo systemctl is-active mariadb nginx    # active y active
sudo ls /opt/printoverse/.env             # existe (de aqui se lee el nombre de la base)
```

Si `getent` no devuelve nada, el DNS (registro `A` de `sistema`) aun no se ha
propagado: esperar y repetir antes de seguir con el paso 4.

## 1. Usuario, carpetas, codigo y entorno Python

```bash
set -euo pipefail

# Usuario de servicio: sin contrasena y sin terminal.
id sistema >/dev/null 2>&1 || sudo useradd --system --home-dir /opt/sistema --shell /usr/sbin/nologin sistema

# /opt/sistema es de 'ubuntu' (el que despliega); solo 'fotos' es de 'sistema'.
sudo mkdir -p /opt/sistema
sudo chown ubuntu:ubuntu /opt/sistema
chmod 755 /opt/sistema
sudo install -d -o sistema -g sistema -m 750 /opt/sistema/fotos
mkdir -p /opt/sistema/publico

# Codigo (repo publico).
if [ -d /opt/sistema/app/.git ]; then
  git -C /opt/sistema/app fetch --quiet origin main
  git -C /opt/sistema/app reset --hard --quiet origin/main
else
  git clone --branch main https://github.com/samechp/3d-organizer.git /opt/sistema/app
fi

# Entorno Python. Si 'venv' da error, instalar: sudo apt-get install -y python3-venv
[ -x /opt/sistema/venv/bin/python ] || python3 -m venv /opt/sistema/venv
/opt/sistema/venv/bin/pip install --quiet --upgrade pip
/opt/sistema/venv/bin/pip install --quiet -r /opt/sistema/app/servidor/requirements.txt
echo "paso 1 listo"
```

## 2 y 3. Base de datos MariaDB y `.env` (UN solo bloque)

Van juntos porque las contrasenas viven en variables del shell: si se cortara la
sesion entre los dos pasos, se perderian. El bloque es seguro de repetir: si
`/opt/sistema/.env` ya existe, no hace nada.

**Antes de pegarlo**, cambiar `CORREO_PERMITIDO` por el correo de Juan (el de su
cuenta de PrintoVerse, el unico que podra entrar).

```bash
set -euo pipefail

CORREO_PERMITIDO='PON_AQUI_EL_CORREO_DE_JUAN'
case "$CORREO_PERMITIDO" in *@*.*) ;; *) echo "Falta poner el correo"; exit 1 ;; esac

if sudo test -f /opt/sistema/.env; then
  echo "/opt/sistema/.env ya existe: no se toca nada (para rehacerlo ver 'Si algo sale mal')"
else
  # Nombre de la base de PrintoVerse: se lee aqui y no se imprime.
  PRINTO_DB=$(sudo grep -m1 '^PRINTO_DB_NAME=' /opt/printoverse/.env | cut -d= -f2- | tr -d "\"' \r" || true)
  [[ "$PRINTO_DB" =~ ^[A-Za-z0-9_]+$ ]] || { echo "No pude leer PRINTO_DB_NAME de /opt/printoverse/.env"; exit 1; }

  # La tabla usuarios debe tener las 4 columnas que usa la app (solo se imprime
  # el nombre de cada columna, nunca datos).
  COLUMNAS=$(sudo mariadb -N -B -e "SHOW COLUMNS FROM \`$PRINTO_DB\`.usuarios" | cut -f1)
  for c in correo clave_hash activo debe_cambiar; do
    if echo "$COLUMNAS" | grep -qx "$c"; then echo "  columna $c: ok"; else echo "  FALTA la columna $c"; exit 1; fi
  done

  # Solo letras y numeros: asi no hace falta codificarlas dentro de la URL.
  PW_SISTEMA=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
  PW_LEE=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
  [ "${#PW_SISTEMA}" -ge 24 ] && [ "${#PW_LEE}" -ge 24 ] || { echo "openssl no genero la contrasena"; exit 1; }

  # Base propia + usuario con todo sobre ella, y un usuario que SOLO puede leer
  # la tabla usuarios de PrintoVerse (para validar la clave sin poder tocar nada).
  # Si 'sudo mariadb' pide contrasena, probar con 'sudo mysql'.
  sudo mariadb <<SQL
CREATE DATABASE IF NOT EXISTS sistema CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'sistema'@'localhost' IDENTIFIED BY '${PW_SISTEMA}';
ALTER USER 'sistema'@'localhost' IDENTIFIED BY '${PW_SISTEMA}';
GRANT ALL PRIVILEGES ON sistema.* TO 'sistema'@'localhost';
CREATE USER IF NOT EXISTS 'sistema_lee'@'localhost' IDENTIFIED BY '${PW_LEE}';
ALTER USER 'sistema_lee'@'localhost' IDENTIFIED BY '${PW_LEE}';
GRANT SELECT ON \`${PRINTO_DB}\`.\`usuarios\` TO 'sistema_lee'@'localhost';
FLUSH PRIVILEGES;
SQL

  # Prueba por TCP (127.0.0.1), que es como se conecta la app. La contrasena va
  # por variable de entorno, no por argumento (no queda en la lista de procesos).
  MYSQL_PWD="$PW_SISTEMA" mariadb -h 127.0.0.1 -u sistema sistema -N -e "SELECT 'sistema: conecta'"
  MYSQL_PWD="$PW_LEE" mariadb -h 127.0.0.1 -u sistema_lee -N -e "SELECT COUNT(*) FROM \`$PRINTO_DB\`.usuarios" >/dev/null && echo "sistema_lee: puede leer usuarios"

  # El .env: se crea vacio con permisos 600 ANTES de escribir nada dentro.
  sudo touch /opt/sistema/.env
  sudo chown sistema:sistema /opt/sistema/.env
  sudo chmod 600 /opt/sistema/.env
  sudo tee /opt/sistema/.env >/dev/null <<ENV
SISTEMA_DB_URL=mysql+pymysql://sistema:${PW_SISTEMA}@localhost/sistema?charset=utf8mb4
PRINTO_USUARIOS_URL=mysql+pymysql://sistema_lee:${PW_LEE}@localhost/${PRINTO_DB}?charset=utf8mb4
SISTEMA_CORREO_PERMITIDO=${CORREO_PERMITIDO}
SISTEMA_FOTOS=/opt/sistema/fotos
ENV

  unset PW_SISTEMA PW_LEE PRINTO_DB COLUMNAS
fi

# Comprobacion: permisos y SOLO los nombres de las variables (no los valores).
sudo ls -l /opt/sistema/.env              # -rw------- sistema sistema
sudo cut -d= -f1 /opt/sistema/.env        # 4 nombres
```

Esperado: `-rw------- ... sistema sistema ... /opt/sistema/.env` y los cuatro
nombres `SISTEMA_DB_URL`, `PRINTO_USUARIOS_URL`, `SISTEMA_CORREO_PERMITIDO`,
`SISTEMA_FOTOS`.

## 4. Certificado de `sistema.printoverse.store`

El problema del huevo y la gallina: nginx no arranca con un bloque HTTPS cuyo
certificado no existe, y certbot necesita un nginx contestando en el puerto 80.
Orden:

1. Un archivo **temporal** de nginx, solo puerto 80, que solo sabe contestar el
   desafio de Let's Encrypt.
2. `certbot certonly --webroot` (pide el certificado y **no toca** ningun
   archivo de nginx; no usar `--nginx`, que reescribiria configuracion).
3. El paso 5 (`desplegar.sh`) instala el archivo de nginx **completo**, encima
   del temporal.

Es el mismo `/var/www/certbot` que ya usa PrintoVerse. El certificado es propio
(`/etc/letsencrypt/live/sistema.printoverse.store/`), no se amplia el de la
tienda. Si el certificado ya existe, el bloque no hace nada (para no pisar la
configuracion completa con la temporal).

```bash
set -euo pipefail

if sudo test -f /etc/letsencrypt/live/sistema.printoverse.store/fullchain.pem; then
  echo "El certificado ya existe: no se hace nada en este paso."
else
  sudo mkdir -p /var/www/certbot

  sudo tee /etc/nginx/sites-available/sistema >/dev/null <<'NGINX'
# TEMPORAL: solo para conseguir el certificado. desplegar.sh lo sustituye.
server {
    listen 80;
    listen [::]:80;
    server_name sistema.printoverse.store;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
NGINX
  sudo ln -sfn /etc/nginx/sites-available/sistema /etc/nginx/sites-enabled/sistema
  sudo nginx -t
  sudo systemctl reload nginx

  # Prueba: un fichero de prueba debe verse desde fuera por HTTP. Si no da 200,
  # certbot tampoco podra validar (DNS sin propagar, firewall del puerto 80...).
  sudo mkdir -p /var/www/certbot/.well-known/acme-challenge
  echo prueba | sudo tee /var/www/certbot/.well-known/acme-challenge/prueba >/dev/null
  curl -s -o /dev/null -w 'desafio visible desde fuera: HTTP %{http_code}\n' http://sistema.printoverse.store/.well-known/acme-challenge/prueba
  sudo rm -f /var/www/certbot/.well-known/acme-challenge/prueba

  # --deploy-hook: nginx no se entera solo de que el certificado se renovo; con
  # el hook se recarga cada vez que certbot lo renueva (queda guardado en
  # /etc/letsencrypt/renewal/sistema.printoverse.store.conf).
  # Si pide un correo (no hay cuenta de certbot previa): añadir -m <correo de Juan>
  sudo certbot certonly --webroot -w /var/www/certbot \
    -d sistema.printoverse.store \
    --non-interactive --agree-tos \
    --deploy-hook 'systemctl reload nginx'
fi

# La renovacion automatica debe funcionar (simulacro, no gasta cupo real).
sudo certbot renew --dry-run --cert-name sistema.printoverse.store
```

Esperado: `desafio visible desde fuera: HTTP 200`, `Successfully received
certificate` y, al final, `Congratulations, all simulated renewals succeeded`.

## 5. Primer despliegue

```bash
bash /opt/sistema/app/servidor/despliegue/desplegar.sh
```

Hace: trae `main`, instala dependencias, copia `servidor/web/` a
`/opt/sistema/publico`, instala el servicio y el nginx completo (con `nginx -t`
antes de recargar), crea las tablas (una sola vez, antes de arrancar), arranca
`sistema` y pregunta a `/health`. Si no responde, vuelve solo a la version
anterior y sale con error.

Esperado, al final: `{"ok":true}` y `DESPLEGADO  <hash>`.

Los despliegues siguientes son solo ese comando (desde Windows:
`ssh -i ~/.ssh/ovh_postiz ubuntu@149.56.129.121 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh'`).

## 6. Comprobaciones finales

Desde el propio servidor o desde Windows (`curl.exe`):

```bash
# La app contesta y la base responde
curl -s https://sistema.printoverse.store/health                     # {"ok":true}

# Sin sesion, la API cierra la puerta
curl -s -o /dev/null -w '%{http_code}\n' https://sistema.printoverse.store/api/yo      # 401

# La pagina, sin cache y sin indexar
curl -sI https://sistema.printoverse.store/ | grep -iE '^(HTTP|cache-control|x-robots-tag|referrer-policy)'
#   HTTP/2 200 ; Cache-Control: no-cache ; X-Robots-Tag: noindex... ; Referrer-Policy: no-referrer

# Reglas de nginx
curl -s -o /dev/null -w '%{http_code}\n' https://sistema.printoverse.store/.env         # 403 (ficheros con punto, nunca)
curl -s -o /dev/null -w '%{http_code}\n' https://sistema.printoverse.store/nada.js      # 404 (no la pagina de inicio)
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' http://sistema.printoverse.store/   # 301 https://...

# Lo que ya existia NO se rompio
curl -s -o /dev/null -w '%{http_code}\n' https://printoverse.store              # 200
curl -s -o /dev/null -w '%{http_code}\n' https://dashboard.printoverse.store    # 200

# El servicio solo escucha en el socket (ningun puerto TCP de gunicorn)
sudo ss -ltnp | grep -c gunicorn || true                                        # 0
ls -l /run/sistema/gunicorn.sock
```

`https://dashboard.printoverse.store` puede dar 200 o el codigo que daba antes
de empezar (anotarlo en el paso 0 si se quiere comparar): lo que importa es que
no cambie.

La prueba de **entrar de verdad** (login contra la tabla real de PrintoVerse) la
hace Juan despues, con su correo y su contrasena de PrintoVerse (o el importador
de perfiles, que tambien entra). Hasta entonces solo esta comprobado que el
usuario `sistema_lee` puede leer la tabla (paso 3).

## Si algo sale mal

**Ver que paso**

```bash
sudo systemctl status sistema --no-pager
sudo journalctl -u sistema -n 80 --no-pager        # registros de la app (-f para verlos en vivo)
sudo tail -n 50 /var/log/nginx/sistema.error.log   # errores de nginx de este sitio
sudo tail -n 50 /var/log/nginx/sistema.access.log
sudo nginx -t
```

**Sintomas conocidos**

- `502 Bad Gateway`: el servicio no esta corriendo. `systemctl status sistema` y
  `journalctl -u sistema`. Si dice `start request repeated too quickly`:
  `sudo systemctl reset-failed sistema && sudo systemctl restart sistema`.
- `Access denied for user 'sistema'...` en el journal: la contrasena del `.env`
  no coincide con la de MariaDB, o MariaDB no reconoce `localhost` por TCP. Se
  rehace el paso 2 y 3 (ver abajo).
- `Falta la variable de entorno SISTEMA_DB_URL`: el `.env` no se esta leyendo.
  `sudo ls -l /opt/sistema/.env` (debe ser `sistema sistema`, 600).
- `Read-only file system` al subir una foto: falta la carpeta en
  `ReadWritePaths` de `sistema.service`, o `/opt/sistema/fotos` no es de
  `sistema`.
- `nginx -t` falla con `cannot load certificate`: falta el paso 4.

**Volver a una version anterior**

`desplegar.sh` ya vuelve solo si la nueva no responde. Para volver a mano a una
version buena (hash de `git log --oneline`):

```bash
cd /opt/sistema/app
git --no-pager log --oneline -8
git reset --hard <hash>
/opt/sistema/venv/bin/pip install --quiet -r servidor/requirements.txt
find /opt/sistema/publico -mindepth 1 -delete && cp -r servidor/web/. /opt/sistema/publico/
sudo systemctl restart sistema
```

(Un `desplegar.sh` posterior vuelve a `origin/main`: para dejar la version
buena de forma permanente hay que revertir el cambio malo en el repo y
desplegar.)

**Quitar el sitio de nginx sin tocar PrintoVerse**

```bash
sudo rm /etc/nginx/sites-enabled/sistema
sudo nginx -t && sudo systemctl reload nginx
```

**Rehacer las contrasenas y el `.env`**

```bash
sudo rm /opt/sistema/.env
# y repetir el bloque "2 y 3" (el ALTER USER pone las contrasenas nuevas en
# MariaDB; despues: sudo systemctl restart sistema)
```
