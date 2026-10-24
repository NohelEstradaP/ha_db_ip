#!/usr/bin/env bash
# Configuración compartida del clúster (IP de los 3 nodos + contraseñas), cifrada para poder
# guardarla en el repositorio público. Cifrado AES-256 con una frase que solo conoce el equipo.
#
#   ./scripts/secretos.sh guardar   cifra la parte compartida del .env en cluster.env.enc (y ofrece subirlo)
#   ./scripts/secretos.sh leer      muestra el contenido descifrado (lo usa instalar.sh)
#
# La frase se pide por teclado, o se toma de la variable HADB_FRASE si está definida.
set -euo pipefail
source "$(dirname "$0")/comun.sh"

ARCHIVO="$RAIZ/cluster.env.enc"
CLAVES="N1_IP N2_IP N3_IP PG_SUPERUSER_PASSWORD PG_REPLICATION_PASSWORD PG_REWIND_PASSWORD APP_PASSWORD"
CIFRADO=(enc -aes-256-cbc -pbkdf2 -iter 200000 -base64 -pass env:HADB_FRASE)

pedir_frase() {
  if [ -z "${HADB_FRASE:-}" ]; then
    read -r -s -p "  ? Frase del clúster: " HADB_FRASE </dev/tty
    echo >&2
  fi
  export HADB_FRASE
}

guardar() {
  cargar_env
  local frase2 contenido clave
  if [ -z "${HADB_FRASE:-}" ]; then
    read -r -s -p "  ? Elige una frase para cifrar (mínimo 12 caracteres): " HADB_FRASE </dev/tty; echo
    [ "${#HADB_FRASE}" -ge 12 ] || fallo "la frase debe tener al menos 12 caracteres"
    read -r -s -p "  ? Repite la frase: " frase2 </dev/tty; echo
    [ "$HADB_FRASE" = "$frase2" ] || fallo "las frases no coinciden"
  fi
  export HADB_FRASE
  contenido=""
  for clave in $CLAVES; do
    contenido="$contenido$clave=${!clave}"$'\n'
  done
  printf '%s' "$contenido" | openssl "${CIFRADO[@]}" -salt > "$ARCHIVO"
  # Comprobar que se puede descifrar antes de darlo por bueno
  openssl "${CIFRADO[@]}" -d < "$ARCHIVO" | grep -q '^APP_PASSWORD=' || fallo "no se pudo verificar el archivo cifrado"
  ok "configuración cifrada en cluster.env.enc"
  aviso "Guarda la frase en un lugar seguro: sin ella no se puede reinstalar un nodo de forma automática."

  if git -C "$RAIZ" rev-parse >/dev/null 2>&1; then
    local r
    read -r -p "  ? ¿Subir cluster.env.enc a GitHub ahora? [S/n] " r </dev/tty
    case "$r" in
      [nN]*) aviso "no se subió; hazlo con git add cluster.env.enc && git commit && git push" ;;
      *)
        git -C "$RAIZ" add cluster.env.enc
        git -C "$RAIZ" commit -q -m "Actualizar la configuración cifrada del clúster"
        git -C "$RAIZ" push -q
        ok "subido a GitHub"
        ;;
    esac
  fi
}

leer() {
  [ -f "$ARCHIVO" ] || fallo "no existe cluster.env.enc"
  pedir_frase
  openssl "${CIFRADO[@]}" -d < "$ARCHIVO" 2>/dev/null || fallo "frase incorrecta"
}

case "${1:-}" in
  guardar) guardar ;;
  leer) leer ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
