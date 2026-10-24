#!/usr/bin/env bash
# Laboratorio local: los 3 nodos del clúster en una sola máquina (solo necesita Docker).
#
#   ./laboratorio/lab.sh iniciar          crea los 3 nodos, la BD y el esquema
#   ./laboratorio/lab.sh estado           patronictl list
#   ./laboratorio/lab.sh carga            arranca 3 generadores (1 tx/s cada uno)
#   ./laboratorio/lab.sh monitor          monitor en vivo (Ctrl+C para salir)
#   ./laboratorio/lab.sh panel            panel web en tiempo real: http://localhost:18080
#   ./laboratorio/lab.sh apagar n1        apagado brusco del nodo (como desconectar la corriente)
#   ./laboratorio/lab.sh detener n1       apagado limpio del nodo
#   ./laboratorio/lab.sh aislar n1        lo deja sin red (partición), sigue encendido
#   ./laboratorio/lab.sh encender n1      vuelve a encender / reconectar el nodo
#   ./laboratorio/lab.sh primario         muestra qué nodo es el primario
#   ./laboratorio/lab.sh parar-carga      detiene los generadores
#   ./laboratorio/lab.sh verificar        verificador de integridad (con la carga detenida)
#   ./laboratorio/lab.sh logs n1          logs de Patroni del nodo
#   ./laboratorio/lab.sh destruir         borra el laboratorio y sus datos
set -euo pipefail
cd "$(dirname "$0")"

RED="hadb-lab_lab"
dc() { docker compose -f docker-compose.yml "$@"; }

ip_de() {
  case "$1" in
    n1) echo 172.30.0.11 ;; n2) echo 172.30.0.12 ;; n3) echo 172.30.0.13 ;;
    *) echo "nodo inválido: $1 (usa n1, n2 o n3)" >&2; exit 1 ;;
  esac
}

# Un contenedor de Patroni que esté vivo, para correr patronictl
patroni_vivo() {
  local n
  for n in n1 n2 n3; do
    if [ "$(docker inspect -f '{{.State.Running}}' "lab-$n-patroni" 2>/dev/null)" = "true" ]; then
      echo "lab-$n-patroni"
      return 0
    fi
  done
  echo "no hay ningún nodo encendido" >&2
  return 1
}

primario() {
  local n
  for n in n1 n2 n3; do
    if docker exec lab-app python -c "
import sys, urllib.request
try:
    sys.exit(0 if urllib.request.urlopen('http://$(ip_de $n):8008/primary', timeout=2).status == 200 else 1)
except Exception:
    sys.exit(1)" 2>/dev/null; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

pctl() { docker exec "$(patroni_vivo)" patronictl -c /etc/patroni/patroni.yml "$@"; }

esperar_primario() {
  for _ in $(seq 1 90); do
    primario >/dev/null && return 0
    sleep 2
  done
  echo "sin primario tras 3 minutos; revisa ./laboratorio/lab.sh logs n1" >&2
  exit 1
}

esperar_replicas() {
  for _ in $(seq 1 90); do
    [ "$(pctl list -f json | grep -o '"State": "streaming"' | wc -l | tr -d ' ')" = "2" ] && return 0
    sleep 2
  done
  echo "las réplicas no llegaron a streaming tras 3 minutos" >&2
  exit 1
}

crear_bd() {
  local p ip
  p=$(primario)
  ip=$(ip_de "$p")
  docker exec -i -e PGPASSWORD=lab-super "lab-$p-patroni" psql -h "$ip" -U postgres -qtA -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE app LOGIN PASSWORD ''lab-app''' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app')\gexec
SELECT 'CREATE DATABASE hadb OWNER app' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'hadb')\gexec
SQL
  if [ "$(docker exec -e PGPASSWORD=lab-app "lab-$p-patroni" psql -h "$ip" -U app -d hadb -qtA \
          -c "SELECT to_regclass('public.cuentas') IS NOT NULL")" != "t" ]; then
    docker exec -i -e PGPASSWORD=lab-app "lab-$p-patroni" psql -h "$ip" -U app -d hadb -q -v ON_ERROR_STOP=1 < ../sql/esquema.sql
  fi
}

parar_carga() {
  docker exec lab-app python -c "
import os, signal
for p in os.listdir('/proc'):
    if p.isdigit() and int(p) != os.getpid():
        try:
            if b'generador.py' in open(f'/proc/{p}/cmdline', 'rb').read():
                os.kill(int(p), signal.SIGINT)
        except OSError:
            pass"
}

cmd="${1:-}"
nodo="${2:-}"
case "$cmd" in
  iniciar)
    # Los 3 nodos usan la misma imagen: se construye una vez para no competir entre ellos
    dc build n1-patroni
    dc up -d
    echo "Esperando primario..."
    esperar_primario
    echo "Esperando a que las 2 réplicas estén en streaming..."
    esperar_replicas
    crear_bd
    pctl list
    echo "Panel HAProxy: http://localhost:17000 (n1), :27000 (n2), :37000 (n3)"
    ;;
  estado)    pctl list ;;
  primario)  primario || { echo "sin primario"; exit 1; } ;;
  carga)
    mkdir -p ../evidencias
    for n in n1 n2 n3; do
      docker exec -d lab-app sh -c "python -u app/generador.py --nombre lab$n > evidencias/lab_generador_$n.log 2>&1"
    done
    echo "3 generadores arrancados. Logs en evidencias/lab_generador_n*.log"
    ;;
  parar-carga) parar_carga; echo "generadores detenidos" ;;
  monitor)   docker exec -it lab-app python app/monitor.py ;;
  panel)
    dc up -d app >/dev/null 2>&1
    if ! curl -s -o /dev/null -m 2 http://localhost:18080/api/estado; then
      # esperar a que el contenedor termine de instalar psycopg
      for _ in $(seq 1 30); do docker exec lab-app python -c "import psycopg" 2>/dev/null && break; sleep 2; done
      docker exec -d lab-app sh -c "python -u app/panel.py > evidencias/lab_panel.log 2>&1"
      sleep 2
    fi
    echo "Panel: http://localhost:18080"
    ;;
  verificar) docker exec lab-app python app/verificar.py --esperar ;;
  apagar)
    ip_de "$nodo" >/dev/null
    dc kill "$nodo-haproxy" "$nodo-patroni" "$nodo"
    echo "$nodo apagado de golpe a las $(date +%T)"
    ;;
  detener)
    ip_de "$nodo" >/dev/null
    dc stop "$nodo-haproxy" "$nodo-patroni" "$nodo"
    echo "$nodo detenido limpiamente a las $(date +%T)"
    ;;
  aislar)
    docker network disconnect "$RED" "lab-$nodo"
    echo "$nodo sin red a las $(date +%T) (sigue encendido)"
    ;;
  encender)
    ip=$(ip_de "$nodo")
    if [ "$(docker inspect -f '{{.State.Running}}' "lab-$nodo")" = "true" ]; then
      # Estaba aislado: solo se le devuelve la red
      docker network connect --ip "$ip" "$RED" "lab-$nodo" 2>/dev/null || true
    else
      # Estaba apagado: su red es nueva, así que Patroni y HAProxy se recrean dentro de ella
      dc up -d "$nodo"
      dc up -d --force-recreate "$nodo-patroni" "$nodo-haproxy"
    fi
    echo "$nodo encendido a las $(date +%T)"
    ;;
  logs)      ip_de "$nodo" >/dev/null; dc logs --tail 60 "$nodo-patroni" ;;
  destruir)  dc down -v --remove-orphans ;;
  *)         sed -n '2,18p' "$0"; exit 1 ;;
esac
