# shellcheck shell=bash
# Funciones compartidas por los scripts del clúster. Se carga con: source scripts/comun.sh
# Compatible con bash 3.2 (el bash que trae macOS).

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ" || exit 1

if [ -t 1 ]; then
  C_VERDE=$'\033[32m'; C_ROJO=$'\033[31m'; C_AMARILLO=$'\033[33m'; C_AZUL=$'\033[36m'; C_NEGRITA=$'\033[1m'; C_FIN=$'\033[0m'
else
  C_VERDE=""; C_ROJO=""; C_AMARILLO=""; C_AZUL=""; C_NEGRITA=""; C_FIN=""
fi

info()   { echo "${C_AZUL}==>${C_FIN} ${C_NEGRITA}$*${C_FIN}"; }
ok()     { echo "${C_VERDE}  ✔${C_FIN} $*"; }
aviso()  { echo "${C_AMARILLO}  !${C_FIN} $*"; }
fallo()  { echo "${C_ROJO}  ✘ $*${C_FIN}" >&2; exit 1; }

# docker sin sudo si se puede; con sudo si el usuario aún no está en el grupo docker (Linux)
dk() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

cargar_env() {
  [ -f "$RAIZ/.env" ] || fallo "No existe .env. Corre primero ./instalar.sh"
  set -a
  # shellcheck disable=SC1091
  . "$RAIZ/.env"
  set +a
}

pctl() {
  dk exec patroni patronictl -c /etc/patroni/patroni.yml "$@"
}

etcd_endpoints() {
  echo "http://$N1_IP:2379,http://$N2_IP:2379,http://$N3_IP:2379"
}

# Imprime la IP del nodo primario actual (vacío si no hay)
ip_primario() {
  local ip
  for ip in "$N1_IP" "$N2_IP" "$N3_IP"; do
    if [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://$ip:8008/primary")" = "200" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}
