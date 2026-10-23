#!/bin/bash
# desplegar.sh - Trae la ultima version desde GitHub y la pone en marcha.
#
#   ssh vps 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh'
#   ssh vps 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh otra-rama'
#
# Se corre como el usuario 'ubuntu' (dueño del clon); lo que necesita permisos
# usa sudo. Es re-ejecutable: correrlo dos veces seguidas no rompe nada.
#
# Si la version nueva no responde, o cualquier paso falla despues de traer el
# codigo, VUELVE SOLA a la anterior: un despliegue que deja el servicio caido es
# peor que no desplegar.
set -Eeuo pipefail

# Este guion vive DENTRO del repositorio que el mismo actualiza, y bash lee los
# guiones a medida que los ejecuta: el `git reset` de mas abajo le cambia el
# fichero bajo los pies y bash sigue leyendo por posicion, con lo que se salta
# lineas o ejecuta trozos partidos. Se corre desde una copia en /tmp.
if [ "${SISTEMA_DESDE_COPIA:-}" != "1" ]; then
  COPIA=$(mktemp /tmp/desplegar-sistema-XXXXXX.sh)
  cp "$0" "$COPIA"
  # Sin trap aqui: 'exec' sustituye este proceso y el trap se perderia. La copia
  # se borra a si misma al terminar (mas abajo).
  SISTEMA_DESDE_COPIA=1 exec bash "$COPIA" "$@"
fi

RESPALDO_NGINX=""
trap 'rm -f "$0" "$RESPALDO_NGINX" "$RESPALDO_NGINX.nuevo"' EXIT

RAMA="${1:-main}"
BASE=/opt/sistema
APP=$BASE/app
PUB=$BASE/publico
FOTOS=$BASE/fotos
VENV=$BASE/venv
SOCKET=/run/sistema/gunicorn.sock
DESPLIEGUE=$APP/servidor/despliegue
SITIO=/etc/nginx/sites-available/sistema

# Sin certificado, nginx -t falla con un mensaje de rutas que no dice la causa.
# Se comprueba AQUI, antes de traer nada: si falta, no hay nada que deshacer.
if ! sudo test -f /etc/letsencrypt/live/sistema.printoverse.store/fullchain.pem; then
  echo "  Falta el certificado de sistema.printoverse.store (montar.md, paso 4)."
  exit 1
fi

cd "$APP"
ANTES=$(git rev-parse HEAD)

echo "== Trayendo '$RAMA' =="
git fetch --quiet origin "$RAMA"
git checkout --quiet "$RAMA" 2>/dev/null || git checkout --quiet -b "$RAMA" "origin/$RAMA"
git reset --hard --quiet "origin/$RAMA"
DESPUES=$(git rev-parse HEAD)
git --no-pager log -1 --format='  %h %s  (%an, %ar)'

if [ "$ANTES" = "$DESPUES" ]; then
  echo "  (sin cambios, se despliega igual por si acaso)"
fi

# Lo que sirve nginx es una COPIA de servidor/web/, no el clon: asi .env, app/,
# scripts/ y pruebas/ quedan fuera del alcance del servidor web por
# construccion, no por una regla que se pueda olvidar.
#
# Es una funcion porque la vuelta atras tiene que publicar EXACTAMENTE lo
# mismo. Se vacia antes de copiar para que un fichero retirado del repositorio
# desaparezca tambien del servidor. Las fotos subidas viven en $FOTOS, aparte, y
# esto no las toca.
publicar_ficheros() {
  sudo mkdir -p "$PUB"
  sudo chown "$(id -un):$(id -gn)" "$PUB"
  find "$PUB" -mindepth 1 -delete
  cp -r "$APP/servidor/web/." "$PUB/"
  chmod -R a+rX "$PUB"
}

# Pone otra vez la configuracion de nginx que habia antes de este despliegue,
# solo si pasa 'nginx -t'.
restaurar_nginx() {
  [ -s "$RESPALDO_NGINX" ] || return 0
  sudo cp "$SITIO" "$RESPALDO_NGINX.nuevo"
  sudo cp "$RESPALDO_NGINX" "$SITIO"
  if sudo nginx -t >/dev/null 2>&1; then
    sudo systemctl reload nginx
  else
    sudo cp "$RESPALDO_NGINX.nuevo" "$SITIO"
  fi
}

# Deshace el despliegue: codigo, dependencias, ficheros publicos, unidad de
# systemd, nginx y servicio. Cada paso con '|| true': si ya esta fallando, que
# un segundo fallo no corte la vuelta atras a medias.
volver_atras() {
  echo "  VOLVIENDO a $(git rev-parse --short "$ANTES")"
  git reset --hard --quiet "$ANTES" || true
  "$VENV/bin/pip" install --quiet -r servidor/requirements.txt || true
  publicar_ficheros || true
  # La unidad tambien: tras el reset, el fichero del repo es el de la version
  # anterior; si esta tanda la habia cambiado, hay que dejarla como estaba.
  sudo cp "$DESPLIEGUE/sistema.service" /etc/systemd/system/sistema.service || true
  sudo systemctl daemon-reload || true
  restaurar_nginx || true
  sudo systemctl reset-failed sistema 2>/dev/null || true
  sudo systemctl restart sistema || true
  echo
  echo "Ultimos registros del intento fallido:"
  { sudo journalctl -u sistema -n 30 --no-pager | sed 's/^/  /'; } || true
}

fallar() {
  # Sin esto, un fallo dentro de la vuelta atras la volveria a lanzar.
  trap - ERR
  set +e
  echo
  echo "  $1"
  volver_atras
  exit 1
}

# Desde aqui el codigo nuevo ya esta en disco: CUALQUIER paso que falle
# (aunque nadie lo haya previsto) tiene que acabar en la vuelta atras, no en un
# 'set -e' que deja el servicio a medias.
trap 'fallar "Fallo inesperado (linea $LINENO)"' ERR

echo
echo "== Dependencias =="
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r servidor/requirements.txt
echo "  al dia"

echo
echo "== Ficheros publicos =="
publicar_ficheros
echo "  $(find "$PUB" -type f | wc -l) ficheros"
# Las fotos de los modelos: dueño 'sistema' (el servicio escribe ahi) y fuera de
# $PUB, que se vacia en cada despliegue.
sudo install -d -o sistema -g sistema -m 750 "$FOTOS"

echo
echo "== Configuracion del sistema =="
# Se guarda la configuracion de nginx que habia: una rota que se quedara puesta
# haria fallar tambien el siguiente 'nginx -s reload' de PrintoVerse.
RESPALDO_NGINX=$(mktemp /tmp/nginx-sistema-XXXXXX.conf)
sudo cp "$SITIO" "$RESPALDO_NGINX" 2>/dev/null || true
sudo cp "$DESPLIEGUE/nginx-sistema.conf" "$SITIO"
sudo ln -sfn "$SITIO" /etc/nginx/sites-enabled/sistema
# El resultado se guarda antes de pasarlo por sed: en una tuberia el codigo de
# salida es el del ULTIMO comando, asi que 'nginx -t | sed' siempre da 0 y una
# configuracion rota pasaria de largo.
if ! salida_nginx=$(sudo nginx -t 2>&1); then
  echo "$salida_nginx" | sed 's/^/  /'
  if [ -s "$RESPALDO_NGINX" ]; then
    sudo cp "$RESPALDO_NGINX" "$SITIO"
  else
    sudo rm -f /etc/nginx/sites-enabled/sistema "$SITIO"
  fi
  fallar "La configuracion de nginx no es valida (se dejo la que habia)."
fi
echo "$salida_nginx" | sed 's/^/  /'
# La unidad se instala solo ahora, con nginx ya comprobado: si arriba algo falla,
# no queda a medias una mitad nueva y otra vieja.
sudo cp "$DESPLIEGUE/sistema.service" /etc/systemd/system/sistema.service
sudo systemctl daemon-reload

echo
echo "== Tablas =="
# Se crean AQUI, una sola vez y antes de arrancar. Con 2 workers arrancando a la
# vez, cada uno haria su propio create_all y en una base vacia pueden pisarse
# ("table already exists"). Corre como 'sistema', que es quien tiene la clave de
# la base en su .env (permisos 600): ubuntu ni siquiera puede leerlo.
if ! sudo -u sistema -H bash -c '
  set -euo pipefail
  set -a; . /opt/sistema/.env; set +a
  cd /opt/sistema/app
  PYTHONDONTWRITEBYTECODE=1 /opt/sistema/venv/bin/python -c \
    "from servidor.app import base; base.crear_tablas(base.motor_sistema())"
'; then
  fallar "No se pudieron crear las tablas (revisa SISTEMA_DB_URL en /opt/sistema/.env)."
fi
echo "  listas"

echo
echo "== Arrancando =="
# Si el intento anterior fallo 5 veces, systemd deja el servicio bloqueado y
# 'restart' ni lo intenta ("start request repeated too quickly"). Se limpia esa
# marca antes de arrancar.
sudo systemctl reset-failed sistema 2>/dev/null || true
# 'enable' y no solo 'restart': sin el, el servicio corre pero no vuelve solo
# despues de reiniciar la maquina.
sudo systemctl enable sistema >/dev/null 2>&1 || true
# Un 'restart' que falla no se trata aparte: la comprobacion de abajo decide, y
# asi el fallo acaba en la vuelta atras con los registros a la vista.
sudo systemctl restart sistema || true
sudo systemctl reload nginx

# El servicio puede quedar "active" y aun asi devolver 500 en cada peticion, asi
# que se pregunta por HTTP, que es lo que de verdad importa. /health ademas
# hace un SELECT 1 contra la base.
echo -n "  esperando a que responda"
sano=0
for _ in $(seq 1 15); do
  sleep 1; echo -n "."
  if curl -fsS --max-time 3 --unix-socket "$SOCKET" http://localhost/health >/dev/null 2>&1; then
    sano=1; break
  fi
done
echo

if [ "$sano" = "1" ]; then
  echo "  responde"
  { curl -s --unix-socket "$SOCKET" http://localhost/health | head -c 200; } || true
  echo
  echo
  echo "DESPLEGADO  $(git rev-parse --short HEAD)"
  exit 0
fi

fallar "NO RESPONDE."
