#!/usr/bin/env bash
# Atajo para patronictl dentro del contenedor. Ejemplos:
#   ./scripts/pctl.sh list
#   ./scripts/pctl.sh history
#   ./scripts/pctl.sh switchover --leader n2 --candidate n1 --force
#   ./scripts/pctl.sh reinit hadb n1 --force
set -euo pipefail
source "$(dirname "$0")/comun.sh"
if [ -t 0 ]; then
  dk exec -it patroni patronictl -c /etc/patroni/patroni.yml "$@"
else
  dk exec -i patroni patronictl -c /etc/patroni/patroni.yml "$@"
fi
