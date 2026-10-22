#!/usr/bin/env bash
# Levanta etcd, Patroni/PostgreSQL y HAProxy en ESTE nodo y espera a que el clúster esté sano.
# Correrlo en las 3 máquinas. La primera vez, etcd espera hasta que haya al menos 2 nodos arriba.
set -euo pipefail
source "$(dirname "$0")/comun.sh"
cargar_env

info "Levantando contenedores en $NODE_NAME ($NODE_IP)"
dk compose up -d
ok "contenedores creados"

info "Esperando quórum de etcd (necesita al menos 2 de los 3 nodos encendidos)"
for i in $(seq 1 90); do
  if dk exec etcd etcdctl --endpoints="http://$NODE_IP:2379" --command-timeout=2s endpoint health >/dev/null 2>&1; then
    ok "etcd con quórum"
    break
  fi
  [ "$i" = 90 ] && fallo "etcd sin quórum tras 3 min. ¿Están los otros nodos encendidos? Prueba ./scripts/probar_puertos.sh"
  sleep 2
done

info "Esperando a que el clúster tenga primario"
for i in $(seq 1 90); do
  if ip_primario >/dev/null; then
    ok "primario: $(ip_primario)"
    break
  fi
  [ "$i" = 90 ] && fallo "sin primario tras 3 min. Revisa: docker compose logs patroni"
  sleep 2
done

sleep 3
pctl list
