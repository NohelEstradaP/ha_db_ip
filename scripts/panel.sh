#!/usr/bin/env bash
# Panel web en tiempo real del clúster. Abrir http://localhost:8080 (o http://<IP de este equipo>:8080 desde otro).
# Uso: ./scripts/panel.sh [--puerto 8080]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/env_app.sh >/dev/null
exec python app/panel.py "$@"
