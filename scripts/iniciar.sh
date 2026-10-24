#!/usr/bin/env bash
# Levanta etcd, Patroni/PostgreSQL y HAProxy en ESTE nodo y espera a que el clúster esté sano.
# Correrlo en las 3 máquinas. La primera vez, etcd espera hasta que haya al menos 2 nodos arriba.
set -euo pipefail
source "$(dirname "$0")/comun.sh"
cargar_env

ETCD_IMAGEN="gcr.io/etcd-development/etcd:v3.5.17"
etcdctl_remoto() { dk run --rm --entrypoint etcdctl "$ETCD_IMAGEN" --endpoints="$OTROS" --command-timeout=5s "$@"; }

# El modo de arranque de etcd se guarda en .env: si cambiara entre ejecuciones, docker compose
# recrearía etcd y Patroni (un failover innecesario si este nodo es el primario).
fijar_estado_etcd() {
  if grep -q '^ETCD_ESTADO_INICIAL=' .env; then
    sed -i.bak "s/^ETCD_ESTADO_INICIAL=.*/ETCD_ESTADO_INICIAL=$1/" .env && rm -f .env.bak
  else
    printf '\n# Modo de arranque de etcd (lo maneja scripts/iniciar.sh)\nETCD_ESTADO_INICIAL=%s\n' "$1" >> .env
  fi
  export ETCD_ESTADO_INICIAL="$1"
}

# Nodo reinstalado (o con su etcd borrado) cuando el clúster ya existe en los otros nodos:
# su etcd debe entrar como miembro "existing". Si arrancara como "new" chocaría (cluster ID mismatch).
preparar_etcd() {
  dk volume inspect hadb_etcd-data >/dev/null 2>&1 && return 0   # ya tiene datos de etcd: arranque normal
  OTROS=""
  local ip id
  for ip in "$N1_IP" "$N2_IP" "$N3_IP"; do
    [ "$ip" = "$NODE_IP" ] && continue
    curl -s -m 2 "http://$ip:2379/health" | grep -q '"health":"true"' && OTROS="${OTROS:+$OTROS,}http://$ip:2379"
  done
  if [ -z "$OTROS" ]; then                                        # nadie más tiene etcd: arranque inicial
    fijar_estado_etcd new
    return 0
  fi
  info "El clúster ya existe y este nodo no tiene datos de etcd: se reincorpora como miembro existente"
  dk pull -q "$ETCD_IMAGEN" >/dev/null
  id=$(etcdctl_remoto member list | awk -F', ' -v n="$NODE_NAME" -v u="http://$NODE_IP:2380" '$3 == n || $4 == u {print $1}')
  if [ -n "$id" ]; then
    etcdctl_remoto member remove "$id" >/dev/null
    ok "miembro anterior de $NODE_NAME ($id) retirado de etcd"
  fi
  etcdctl_remoto member add "$NODE_NAME" --peer-urls="http://$NODE_IP:2380" >/dev/null
  ok "$NODE_NAME agregado de nuevo al clúster de etcd"
  fijar_estado_etcd existing
}

preparar_etcd

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

info "Esperando a que $NODE_NAME esté sincronizado (una copia completa puede tardar unos minutos)"
for i in $(seq 1 150); do
  # Listo cuando es el primario (running) o una réplica que ya recibe WAL (streaming)
  estado=$(pctl list -f json 2>/dev/null | python3 -c "import json, sys
m = next((m for m in json.load(sys.stdin) if m['Member'] == '$NODE_NAME'), {})
print('listo' if (m.get('Role') == 'Leader' and m.get('State') == 'running') or m.get('State') == 'streaming' else m.get('State', ''))") || true
  if [ "$estado" = listo ]; then ok "$NODE_NAME sincronizado"; break; fi
  [ "$i" = 150 ] && aviso "$NODE_NAME sigue en '${estado:-sin estado}' tras 5 min; revisa: docker compose logs patroni"
  sleep 2
done
pctl list
