#!/usr/bin/env bash
# Generador de carga de ESTE equipo, en segundo plano.
#   ./scripts/carga.sh iniciar [--tps 1]   ./scripts/carga.sh detener   ./scripts/carga.sh estado
set -euo pipefail
source "$(dirname "$0")/comun.sh"
cargar_env
mkdir -p evidencias
PIDF="evidencias/.generador.pid"
LOG="evidencias/generador_$NODE_NAME.log"

activo() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

case "${1:-}" in
  iniciar)
    shift
    if activo; then ok "el generador ya está corriendo (pid $(cat "$PIDF"))"; exit 0; fi
    # shellcheck disable=SC1091
    source scripts/env_app.sh >/dev/null
    nohup python -u app/generador.py --nombre "$NODE_NAME" "$@" >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
    sleep 3
    activo || fallo "el generador no arrancó; revisa $LOG"
    ok "generador de $NODE_NAME corriendo (pid $(cat "$PIDF")) · log: $LOG"
    ;;
  detener)
    # Con SIGTERM: un proceso lanzado en segundo plano ignora Ctrl+C (SIGINT)
    if activo; then kill -TERM "$(cat "$PIDF")"; rm -f "$PIDF"; ok "generador detenido"
    else aviso "no había generador corriendo"; rm -f "$PIDF"; fi
    ;;
  estado)
    if activo; then ok "corriendo (pid $(cat "$PIDF"))"; tail -2 "$LOG"
    else aviso "detenido"; fi
    ;;
  *) sed -n '2,3p' "$0"; exit 1 ;;
esac
