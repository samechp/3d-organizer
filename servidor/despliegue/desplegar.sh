#!/bin/bash
# desplegar.sh - Trae la ultima version desde GitHub y la pone en marcha.
#
#   ssh vps 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh'
#   ssh vps 'bash /opt/sistema/app/servidor/despliegue/desplegar.sh otra-rama'
#
# Se corre como el usuario 'ubuntu' (dueño del clon); lo que necesita permisos
# usa sudo. Es re-ejecutable: correrlo dos veces seguidas no rompe nada.
#
# Si la version nueva no responde, VUELVE SOLA a la anterior: un despliegue que
# deja el servicio caido es peor que no desplegar.
set -euo pipefail

# Este guion vive DENTRO del repositorio que el mismo actualiza, y bash lee los
# guiones a medida que los ejecuta: el `git reset` de mas abajo le cambia el
# fichero bajo los pies y bash sigue leyendo por posicion, con lo que se salta
# lineas o ejecuta trozos partidos. Se corre desde una copia en /tmp.
if [ "${SISTEMA_DESDE_COPIA:-}" != "1" ]; then
  COPIA=$(mktemp /tmp/desplegar-sistema-XXXXXX.sh)
  cp "$0" "$COPIA"
  trap 'rm -f "$COPIA"' EXIT
  SISTEMA_DESDE_COPIA=1 exec bash "$COPIA" "$@"
fi

RAMA="${1:-main}"
BASE=/opt/sistema
APP=$BASE/app
PUB=$BASE/publico
FOTOS=$BASE/fotos
VENV=$BASE/venv
SOCKET=/run/sistema/gunicorn.sock
DESPLIEGUE=$APP/servidor/despliegue

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
# Es una funcion porque la vuelta atras del final tiene que publicar
# EXACTAMENTE lo mismo. Se vacia antes de copiar para que un fichero retirado
# del repositorio desaparezca tambien del servidor. Las fotos subidas viven en
# $FOTOS, aparte, y esto no las toca.
publicar_ficheros() {
  sudo mkdir -p "$PUB"
  sudo chown "$(id -un):$(id -gn)" "$PUB"
  find "$PUB" -mindepth 1 -delete
  cp -r "$APP/servidor/web/." "$PUB/"
  chmod -R a+rX "$PUB"
}

# Deshace el despliegue: codigo, dependencias, ficheros publicos y servicio.
# Cada paso con '|| true': si ya esta fallando, que un segundo fallo no corte la
# vuelta atras a medias.
volver_atras() {
  echo "  VOLVIENDO a $(git rev-parse --short "$ANTES")"
  git reset --hard --quiet "$ANTES" || true
  "$VENV/bin/pip" install --quiet -r servidor/requirements.txt || true
  publicar_ficheros || true
  sudo systemctl restart sistema || true
  echo
  echo "Ultimos registros del intento fallido:"
  sudo journalctl -u sistema -n 30 --no-pager | sed 's/^/  /' || true
}

fallar() {
  echo
  echo "  $1"
  volver_atras
  exit 1
}

echo
echo "== Dependencias =="
"$VENV/bin/pip" install --quiet --upgrade pip
if ! "$VENV/bin/pip" install --quiet -r servidor/requirements.txt; then
  fallar "No se pudieron instalar las dependencias."
fi
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
# Sin certificado, nginx -t falla con un mensaje de rutas que no dice la causa.
# Mejor avisar de lo que de verdad falta (montar.md, paso 4), y antes de tocar
# nada de nginx.
if ! sudo test -f /etc/letsencrypt/live/sistema.printoverse.store/fullchain.pem; then
  echo "  Falta el certificado de sistema.printoverse.store (montar.md, paso 4)."
  exit 1
fi
sudo cp "$DESPLIEGUE/sistema.service" /etc/systemd/system/sistema.service
# Se guarda la configuracion de nginx que habia: una rota que se quedara puesta
# haria fallar tambien el siguiente 'nginx -s reload' de PrintoVerse.
SITIO=/etc/nginx/sites-available/sistema
RESPALDO_NGINX=$(mktemp /tmp/nginx-sistema-XXXXXX.conf)
sudo cp "$SITIO" "$RESPALDO_NGINX" 2>/dev/null || true
sudo cp "$DESPLIEGUE/nginx-sistema.conf" "$SITIO"
sudo ln -sfn "$SITIO" /etc/nginx/sites-enabled/sistema
# El resultado se guarda antes de pasarlo por sed: en una tuberia el codigo de
# salida es el del ULTIMO comando, asi que 'nginx -t | sed' siempre da 0 y una
# configuracion rota pasaria de largo.
if ! salida_nginx=$(sudo nginx -t 2>&1); then
  echo "$salida_nginx" | sed 's/^/  /'
  echo
  if [ -s "$RESPALDO_NGINX" ]; then
    sudo cp "$RESPALDO_NGINX" "$SITIO"
    echo "  La configuracion de nginx no es valida. Se dejo la anterior."
  else
    sudo rm -f /etc/nginx/sites-enabled/sistema "$SITIO"
    echo "  La configuracion de nginx no es valida. Se quito para no romper nginx."
  fi
  rm -f "$RESPALDO_NGINX"
  exit 1
fi
rm -f "$RESPALDO_NGINX"
echo "$salida_nginx" | sed 's/^/  /'
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
sudo systemctl restart sistema
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
  curl -s --unix-socket "$SOCKET" http://localhost/health | head -c 200
  echo
  echo
  echo "DESPLEGADO  $(git rev-parse --short HEAD)"
  exit 0
fi

fallar "NO RESPONDE."
