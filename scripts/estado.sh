#!/usr/bin/env bash
# Muestra el estado del clúster: miembros de Patroni, etcd y quién es primario según la API REST.
set -uo pipefail
source "$(dirname "$0")/comun.sh"
cargar_env

info "Patroni"
pctl list || aviso "patronictl no respondió en este nodo"

info "etcd"
dk exec etcd etcdctl --endpoints="$(etcd_endpoints)" --command-timeout=2s endpoint status -w table 2>/dev/null \
  || aviso "algún endpoint de etcd no responde"

info "API REST de Patroni"
for par in "n1 $N1_IP" "n2 $N2_IP" "n3 $N3_IP"; do
  set -- $par
  codigo=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$2:8008/primary")
  case "$codigo" in
    200) echo "  $1 ($2): PRIMARIO" ;;
    503) echo "  $1 ($2): réplica" ;;
    *)   echo "  $1 ($2): NO RESPONDE" ;;
  esac
done
