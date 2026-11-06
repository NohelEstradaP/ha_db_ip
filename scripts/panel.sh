#!/usr/bin/env bash
# Panel web en tiempo real del clúster. Abrir http://localhost:8080 (o http://<IP de este equipo>:8080 desde otro).
# Uso: ./scripts/panel.sh [--puerto 8080] [--solo-lectura]
#      ./scripts/panel.sh --fondo [...]     lo deja corriendo en segundo plano (log en evidencias/panel.log)
#      ./scripts/panel.sh --detener         detiene el panel en segundo plano
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p evidencias
PIDF="evidencias/.panel.pid"
# Tras un reinicio el PID guardado puede pertenecer a otro proceso: se confirma que sea el panel
activo() { [ -f "$PIDF" ] && ps -p "$(cat "$PIDF")" -o command= 2>/dev/null | grep -q "app/panel.py"; }

if [ "${1:-}" = "--detener" ]; then
  if activo; then kill -TERM "$(cat "$PIDF")"; echo "panel detenido"; else echo "no había panel en segundo plano"; fi
  rm -f "$PIDF"
  exit 0
fi

# shellcheck disable=SC1091
source scripts/env_app.sh >/dev/null
if [ "${1:-}" = "--fondo" ]; then
  shift
  if activo; then echo "El panel ya está corriendo (pid $(cat "$PIDF")): http://localhost:8080"; exit 0; fi
  nohup python -u app/panel.py "$@" >> evidencias/panel.log 2>&1 &
  echo $! > "$PIDF"
  sleep 2
  kill -0 "$(cat "$PIDF")" 2>/dev/null || { echo "el panel no arrancó; revisa evidencias/panel.log" >&2; exit 1; }
  echo "Panel en segundo plano (pid $(cat "$PIDF")): http://localhost:8080 · detener: ./scripts/panel.sh --detener"
  exit 0
fi
exec python app/panel.py "$@"
