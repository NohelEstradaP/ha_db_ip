#!/usr/bin/env bash
# Prueba desde ESTE nodo que los puertos del clúster respondan en los 3 nodos.
set -u
cd "$(dirname "$0")/.." || exit 1
set -a; source .env; set +a

for ip in "$N1_IP" "$N2_IP" "$N3_IP"; do
  for p in 2379 2380 5432 8008 5000 7000; do
    if nc -z -w 2 "$ip" "$p" 2>/dev/null; then
      echo "OK     $ip:$p"
    else
      echo "FALLA  $ip:$p"
    fi
  done
done
