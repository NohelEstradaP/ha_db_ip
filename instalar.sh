#!/usr/bin/env bash
# Prepara ESTE equipo como nodo del clúster hadb (PostgreSQL + Patroni + etcd + HAProxy en Docker).
# Soporta macOS (Apple Silicon) y Pop!_OS / Ubuntu. Se puede volver a correr: salta lo que ya está hecho.
#
# Uso:
#   ./instalar.sh            instalación completa (red con Tailscale)
#   ./instalar.sh --lan      sin Tailscale: usa las IP de la red local
#   ./instalar.sh --solo-env solo vuelve a generar el archivo .env
#   ./instalar.sh -y         responde "sí" a todas las confirmaciones
set -euo pipefail
source "$(dirname "$0")/scripts/comun.sh"

MODO_RED="tailscale"
SOLO_ENV=0
SI_A_TODO=0
for arg in "$@"; do
  case "$arg" in
    --lan) MODO_RED="lan" ;;
    --solo-env) SOLO_ENV=1 ;;
    -y|--si) SI_A_TODO=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) fallo "opción desconocida: $arg" ;;
  esac
done

# ---------------------------------------------------------------- utilidades de interacción

confirmar() {   # confirmar "pregunta"  -> 0 si sí (por defecto sí)
  [ "$SI_A_TODO" = 1 ] && return 0
  local r
  read -r -p "  ? $1 [S/n] " r </dev/tty
  case "$r" in [nN]*) return 1 ;; *) return 0 ;; esac
}

preguntar() {   # preguntar VARIABLE "texto" "valor_por_defecto"
  local var="$1" texto="$2" defecto="${3:-}" r
  if [ -n "$defecto" ]; then
    read -r -p "  ? $texto [$defecto]: " r </dev/tty
    r="${r:-$defecto}"
  else
    while [ -z "${r:-}" ]; do read -r -p "  ? $texto: " r </dev/tty; done
  fi
  eval "$var=\$r"
}

es_ip() {
  echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

pedir_ip() {    # pedir_ip VARIABLE "texto" "valor_por_defecto"  -> repite hasta que sea una IP válida
  local valor
  while :; do
    preguntar valor "$2" "$3"
    es_ip "$valor" && break
    echo "    IP no válida."
    valor=""
  done
  eval "$1=\$valor"
}

# ---------------------------------------------------------------- detección del sistema

detectar_so() {
  case "$(uname -s)" in
    Darwin)
      SO="mac"
      [ "$(uname -m)" = "arm64" ] || aviso "Mac Intel detectada: debería funcionar igual, pero el plan asume Apple Silicon"
      ;;
    Linux)
      SO="linux"
      # shellcheck disable=SC1091
      . /etc/os-release
      case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*|*" pop "*|*" debian "*) ;;
        *) fallo "distribución no soportada: ${PRETTY_NAME:-desconocida} (se esperaba Pop!_OS/Ubuntu)" ;;
      esac
      ;;
    *) fallo "sistema no soportado: $(uname -s)" ;;
  esac
  ok "sistema: $SO ($(uname -m))"
}

# CLI de Tailscale: en macOS se usa la que trae la app (la de Homebrew no habla con la app)
tailscale_cli() {
  if [ "$SO" = "mac" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"
  else
    tailscale "$@"
  fi
}

ip_local() {
  if [ "$MODO_RED" = "tailscale" ]; then
    tailscale_cli ip -4 2>/dev/null | head -1
  elif [ "$SO" = "mac" ]; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
  else
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}'
  fi
}

# ---------------------------------------------------------------- pasos

paso_paquetes() {
  info "Paquetes base"
  if [ "$SO" = "mac" ]; then
    if ! command -v brew >/dev/null; then
      confirmar "Homebrew no está instalado. ¿Instalarlo?" || fallo "Homebrew es necesario en macOS"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    local faltan=""
    for p in git jq watch; do
      command -v "$p" >/dev/null || faltan="$faltan $p"
    done
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null || faltan="$faltan python@3.12"
    # shellcheck disable=SC2086
    [ -z "$faltan" ] || brew install $faltan
  else
    sudo apt-get update -qq
    sudo apt-get install -y -qq git curl ca-certificates gnupg jq netcat-openbsd openssl \
      python3 python3-venv python3-pip >/dev/null
  fi
  ok "git, jq, python3, curl"
}

paso_docker() {
  info "Docker"
  if [ "$SO" = "mac" ]; then
    # Sirve Docker Desktop u OrbStack (mismo CLI 'docker'); solo se instala Docker Desktop si no hay ninguno
    local app="Docker"
    if [ -d /Applications/OrbStack.app ]; then
      app="OrbStack"
    elif [ ! -d /Applications/Docker.app ]; then
      brew install --cask docker
    fi
    if ! docker info >/dev/null 2>&1; then
      open -a "$app"
      echo "    Esperando a que $app arranque (la primera vez puede pedir permisos o aceptar términos)..."
      local i
      for i in $(seq 1 90); do
        docker info >/dev/null 2>&1 && break
        [ "$i" = 90 ] && fallo "$app no arrancó. Ábrelo a mano y vuelve a correr ./instalar.sh"
        sleep 2
      done
    fi
    if [ "$app" = "OrbStack" ]; then
      aviso "Usando OrbStack. En OrbStack → Settings activa 'Start at login'."
    else
      aviso "En Docker Desktop → Settings → General activa 'Start Docker Desktop when you sign in'"
      aviso "y en Resources pon Memory ≥ 4 GB."
    fi
  else
    if ! sudo docker compose version >/dev/null 2>&1; then
      for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        sudo apt-get remove -y -qq "$pkg" >/dev/null 2>&1 || true
      done
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      # shellcheck disable=SC1091
      . /etc/os-release
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -qq
      sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    fi
    sudo systemctl enable --now docker containerd >/dev/null 2>&1
    if ! id -nG "$USER" | grep -qw docker; then
      sudo usermod -aG docker "$USER"
      aviso "Se agregó $USER al grupo docker. Cierra sesión y vuelve a entrar para usar docker sin sudo."
    fi
  fi
  dk compose version >/dev/null || fallo "docker compose no funciona"
  ok "$(dk version --format 'Docker {{.Server.Version}}') · $(dk compose version --short | sed 's/^/Compose /')"
}

paso_tailscale() {
  [ "$MODO_RED" = "tailscale" ] || { aviso "modo LAN: se omite Tailscale"; return 0; }
  info "Tailscale"
  if [ "$SO" = "mac" ]; then
    [ -d /Applications/Tailscale.app ] || brew install --cask tailscale-app
    open -a Tailscale
  else
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    sudo systemctl enable --now tailscaled >/dev/null 2>&1
  fi

  if [ -z "$(ip_local)" ]; then
    if [ "$SO" = "mac" ]; then
      echo "    Inicia sesión en la app de Tailscale (ícono en la barra de menú)."
    else
      echo "    Abre la URL que aparece abajo e inicia sesión con la MISMA cuenta en las 3 máquinas."
      sudo tailscale up
    fi
    local i
    for i in $(seq 1 150); do
      [ -n "$(ip_local)" ] && break
      [ "$i" = 150 ] && fallo "Tailscale sin IP tras 5 min. Inicia sesión y vuelve a correr ./instalar.sh"
      sleep 2
    done
  fi
  ok "IP Tailscale de este equipo: $(ip_local)"
  aviso "En https://login.tailscale.com/admin/machines desactiva 'key expiry' de las 3 máquinas."
}

paso_energia() {
  info "Evitar reposo (si el equipo se duerme, el clúster lo ve como apagado)"
  confirmar "¿Desactivar la suspensión automática de este equipo?" || { aviso "omitido"; return 0; }
  if [ "$SO" = "mac" ]; then
    sudo pmset -c sleep 0 disksleep 0
    ok "macOS: no se duerme con el cargador conectado. No cierres la tapa durante la demo."
  else
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
    sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
    sudo sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
    ok "Pop!_OS: suspensión desactivada (se aplica completo tras reiniciar sesión)"
  fi
}

paso_hora() {
  info "Hora sincronizada"
  if [ "$SO" = "mac" ]; then
    sudo systemsetup -setusingnetworktime on >/dev/null 2>&1 || aviso "actívala en Ajustes → General → Fecha y hora"
  else
    sudo timedatectl set-ntp true
  fi
  ok "$(date)"
}

paso_puertos() {
  info "Puertos libres"
  local p ocupados=""
  for p in 2379 2380 5432 5000 5001 7000 8008; do
    # Los contenedores de este mismo proyecto no cuentan como ocupados
    if dk ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(etcd|patroni|haproxy)$'; then break; fi
    if [ "$SO" = "mac" ]; then
      lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && ocupados="$ocupados $p"
    else
      sudo ss -ltn "sport = :$p" | grep -q LISTEN && ocupados="$ocupados $p"
    fi
  done
  if [ -n "$ocupados" ]; then
    aviso "puertos ocupados:$ocupados"
    if [ "$SO" = "mac" ] && lsof -nP -iTCP:5000 -iTCP:7000 -sTCP:LISTEN 2>/dev/null | grep -q '^ControlCe'; then
      aviso "5000 y 7000 los usa el Receptor AirPlay de macOS. Desactívalo en:"
      aviso "Ajustes del Sistema → General → AirDrop y Handoff → Receptor AirPlay"
    fi
    aviso "si es un PostgreSQL local: 'brew services stop postgresql@16' (Mac) o 'sudo systemctl disable --now postgresql' (Linux)"
    confirmar "¿Continuar de todos modos?" || exit 1
  else
    ok "2379 2380 5432 5000 5001 7000 8008"
  fi
}

paso_env() {
  info "Archivo .env de este nodo"
  if [ -f .env ] && [ "$SOLO_ENV" = 0 ]; then
    if confirmar "Ya existe .env. ¿Conservarlo?"; then
      cargar_env
      ok "se usa el .env existente ($NODE_NAME, $NODE_IP)"
      return 0
    fi
  fi

  local mi_ip nombre n1 n2 n3 propia
  mi_ip="$(ip_local)"
  echo "    Este equipo: $(hostname) · IP detectada ($MODO_RED): ${mi_ip:-no detectada}"
  while :; do
    preguntar nombre "¿Qué nodo es este equipo? (n1, n2 o n3)" ""
    case "$nombre" in n1|n2|n3) break ;; *) echo "    Escribe n1, n2 o n3." ;; esac
  done

  echo "    Escribe las IP de los 3 nodos (las mismas en las 3 máquinas)."
  local d1="" d2="" d3=""
  [ "$nombre" = n1 ] && d1="$mi_ip"
  [ "$nombre" = n2 ] && d2="$mi_ip"
  [ "$nombre" = n3 ] && d3="$mi_ip"
  pedir_ip n1 "IP de n1" "$d1"
  pedir_ip n2 "IP de n2" "$d2"
  pedir_ip n3 "IP de n3" "$d3"
  [ "$n1" != "$n2" ] && [ "$n1" != "$n3" ] && [ "$n2" != "$n3" ] || fallo "las 3 IP deben ser distintas"
  case "$nombre" in n1) propia="$n1" ;; n2) propia="$n2" ;; n3) propia="$n3" ;; esac
  [ -z "$mi_ip" ] || [ "$propia" = "$mi_ip" ] || aviso "la IP de $nombre ($propia) no coincide con la detectada ($mi_ip)"

  local c1 c2 c3 c4
  echo
  echo "    Las 4 contraseñas deben ser IGUALES en las 3 máquinas."
  # Esta pregunta nunca se responde sola con -y: generar contraseñas en el 2.º equipo rompería el clúster
  local primero
  read -r -p "  ? ¿Es el PRIMER equipo que configuras? (se generan contraseñas nuevas) [s/N] " primero </dev/tty
  if [[ "$primero" == [sS]* ]]; then
    c1=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    c2=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    c3=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    c4=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
  else
    preguntar c1 "PG_SUPERUSER_PASSWORD" ""
    preguntar c2 "PG_REPLICATION_PASSWORD" ""
    preguntar c3 "PG_REWIND_PASSWORD" ""
    preguntar c4 "APP_PASSWORD" ""
  fi

  umask 077
  cat > .env <<EOF
# Generado por instalar.sh el $(date '+%Y-%m-%d %H:%M'). NO subir a GitHub.
# Modo de red: $MODO_RED

# ---- Identidad de ESTE nodo ----
NODE_NAME=$nombre
NODE_IP=$propia

# ---- IP de los 3 nodos (idénticas en las 3 máquinas) ----
N1_IP=$n1
N2_IP=$n2
N3_IP=$n3

# ---- Contraseñas (idénticas en las 3 máquinas) ----
PG_SUPERUSER_PASSWORD=$c1
PG_REPLICATION_PASSWORD=$c2
PG_REWIND_PASSWORD=$c3
APP_PASSWORD=$c4
EOF
  umask 022
  cargar_env
  ok ".env creado para $NODE_NAME ($NODE_IP)"
  echo
  echo "    ${C_NEGRITA}Copia estas 4 líneas: las vas a pegar al configurar los otros equipos:${C_FIN}"
  grep PASSWORD .env | sed 's/^/      /'
  echo
}

paso_firewall() {
  [ "$SO" = "linux" ] || return 0
  sudo ufw status 2>/dev/null | grep -q "Status: active" || return 0
  info "Firewall (ufw activo)"
  local ip
  for ip in "$N1_IP" "$N2_IP" "$N3_IP"; do
    sudo ufw allow from "$ip" >/dev/null
  done
  ok "permitido el tráfico desde $N1_IP, $N2_IP y $N3_IP"
}

paso_python() {
  info "Entorno Python de la aplicación"
  [ -d .venv ] || python3 -m venv .venv
  if ! .venv/bin/python -c 'import psycopg' 2>/dev/null; then
    # Tiempo de espera y reintentos altos: en redes lentas o de universidad pip corta a los 15 s
    .venv/bin/pip install -q --disable-pip-version-check --timeout 120 --retries 10 -r app/requirements.txt \
      || fallo "no se pudo descargar psycopg (red lenta o bloqueada). Vuelve a correr ./instalar.sh o prueba otra red"
  fi
  ok "$(.venv/bin/python -c 'import psycopg; print("psycopg", psycopg.__version__)')"
}

paso_imagenes() {
  info "Imágenes de Docker (la primera vez tarda unos minutos)"
  dk compose pull etcd haproxy
  dk compose build patroni
  ok "imágenes listas"
}

resumen() {
  echo
  info "Nodo $NODE_NAME listo"
  cat <<EOF

  Siguientes pasos (cuando los 3 equipos hayan corrido ./instalar.sh):

    1. Probar la red entre los 3:        ./scripts/probar_puertos.sh   (antes de iniciar, solo responde lo que ya esté arriba)
    2. Levantar el nodo (en los 3):     ./scripts/iniciar.sh
    3. Crear la BD (UNA vez, en uno):   ./scripts/crear_bd.sh
    4. Estado del clúster:              ./scripts/estado.sh
    5. Carga y monitoreo:               source scripts/env_app.sh
                                        python app/generador.py --nombre $NODE_NAME
                                        python app/monitor.py
                                        python app/verificar.py --esperar

  Panel de HAProxy: http://$NODE_IP:7000
EOF
}

# ---------------------------------------------------------------- principal

detectar_so
if [ "$SOLO_ENV" = 1 ]; then
  paso_env
  exit 0
fi
paso_paquetes
paso_docker
paso_tailscale
paso_energia
paso_hora
paso_puertos
paso_env
paso_firewall
paso_python
paso_imagenes
resumen
