#!/usr/bin/env python3
"""Monitor en vivo del clúster: rol de cada nodo, lag, ritmo de cambios e invariantes."""
import csv
import json
import os
import time
import urllib.request
from datetime import datetime

import psycopg

NODOS = {"n1": os.environ["N1_IP"], "n2": os.environ["N2_IP"], "n3": os.environ["N3_IP"]}
DSN = os.environ["HA_DSN"]
INTERVALO = 2


def estado_patroni(ip):
    try:
        with urllib.request.urlopen(f"http://{ip}:8008/patroni", timeout=1.5) as r:
            return json.load(r)
    except Exception:
        return None


def metricas(conn):
    return conn.execute(
        """SELECT count(*) FILTER (WHERE creado > now() - interval '60 seconds'),
                  count(*),
                  (SELECT sum(saldo) FROM cuentas)
           FROM movimientos"""
    ).fetchone()


def main():
    os.makedirs("evidencias", exist_ok=True)
    ruta = os.path.join("evidencias", f"monitor_{datetime.now():%Y%m%d_%H%M%S}.csv")
    conn = None
    with open(ruta, "w", newline="") as f:
        log = csv.writer(f)
        log.writerow(["timestamp", "n1", "n2", "n3", "primario",
                      "tx_ultimo_min", "cambios_ultimo_min", "total_movimientos", "suma_saldos"])
        while True:
            estados = {n: estado_patroni(ip) for n, ip in NODOS.items()}
            lsn_primario = None
            for e in estados.values():
                if e and e.get("role") in ("primary", "master"):
                    lsn_primario = e.get("xlog", {}).get("location")

            filas = []
            for n, e in estados.items():
                if e is None:
                    filas.append((n, "CAÍDO", "-", "-", "-"))
                    continue
                rol = e.get("role", "?")
                if rol == "master":
                    rol = "primary"
                lag = "-"
                if rol == "replica" and lsn_primario is not None:
                    replay = e.get("xlog", {}).get("replayed_location")
                    if replay is not None:
                        lag = f"{max(0, lsn_primario - replay)} B"
                filas.append((n, rol, e.get("state", "?"), e.get("timeline", "-"), lag))

            try:
                if conn is None or conn.closed:
                    conn = psycopg.connect(DSN, autocommit=True, connect_timeout=2)
                tx_min, total, suma = metricas(conn)
                primario = conn.info.host
            except psycopg.Error:
                conn, tx_min, total, suma, primario = None, None, None, None, "SIN PRIMARIO"

            os.system("clear")
            print(f"Clúster hadb  {datetime.now():%Y-%m-%d %H:%M:%S}\n")
            print(f"{'nodo':5} {'rol':9} {'estado':10} {'TL':>3} {'lag':>10}")
            for n, rol, estado, tl, lag in filas:
                print(f"{n:5} {rol:9} {estado:10} {str(tl):>3} {lag:>10}")
            print()
            print(f"Primario (vía libpq) : {primario}")
            if tx_min is not None:
                marca = "OK" if tx_min * 3 >= 90 else "BAJO"
                integridad = "OK" if suma == 1000000 else "¡ALERTA!"
                print(f"Transacciones / min  : {tx_min}")
                print(f"Cambios / min        : {tx_min * 3}  [{marca}, mínimo 90]")
                print(f"Total movimientos    : {total}")
                print(f"Suma de saldos       : {suma:,.2f}  [{integridad}]")

            roles = {n: r for n, r, *_ in filas}
            log.writerow([datetime.now().isoformat(timespec="seconds"),
                          roles["n1"], roles["n2"], roles["n3"], primario,
                          tx_min, None if tx_min is None else tx_min * 3, total, suma])
            f.flush()
            time.sleep(INTERVALO)


if __name__ == "__main__":
    main()
