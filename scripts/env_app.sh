# shellcheck shell=bash
# Prepara la terminal para correr los programas de app/. Uso:  source scripts/env_app.sh
_raiz="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$_raiz" || return 1
if [ ! -f .env ] || [ ! -d .venv ]; then
  echo "Falta .env o .venv. Corre primero ./instalar.sh" >&2
  return 1
fi
set -a
. ./.env
set +a
. .venv/bin/activate
export HA_DSN="host=$N1_IP,$N2_IP,$N3_IP port=5432 dbname=hadb user=app password=$APP_PASSWORD target_session_attrs=read-write connect_timeout=3 keepalives=1 keepalives_idle=5 keepalives_interval=2 keepalives_count=3 tcp_user_timeout=10000"
echo "Listo. Ejemplos:"
echo "  python app/generador.py --nombre $NODE_NAME"
echo "  python app/monitor.py"
echo "  python app/verificar.py --esperar"
unset _raiz
