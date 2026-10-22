#!/usr/bin/env python3
"""Verificador de integridad: compara los 3 nodos directamente (puerto 5432)."""
import os
import sys
import time

import psycopg

NODOS = {"n1": os.environ["N1_IP"], "n2": os.environ["N2_IP"], "n3": os.environ["N3_IP"]}
CLAVE = os.environ["APP_PASSWORD"]
SUMA_ESPERADA = 1000000

CONSULTA = """
SELECT pg_is_in_recovery(),
       (SELECT count(*) FROM cuentas),
       (SELECT sum(saldo) FROM cuentas),
       (SELECT md5(string_agg(id || ':' || saldo, ',' ORDER BY id)) FROM cuentas),
       (SELECT count(*) FROM movimientos),
       (SELECT md5(string_agg(generador || ':' || seq || ':' || origen || ':' || destino
                              || ':' || monto, ',' ORDER BY generador, seq)) FROM movimientos),
       (SELECT coalesce(sum(faltantes), 0) FROM
          (SELECT max(seq) - count(*) AS faltantes FROM movimientos GROUP BY generador) x),
       CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END
"""


def dsn(ip):
    return f"host={ip} port=5432 dbname=hadb user=app password={CLAVE} connect_timeout=3"


def leer(ip):
    try:
        with psycopg.connect(dsn(ip)) as conn:
            return conn.execute(CONSULTA).fetchone()
    except psycopg.Error as e:
        return e


def main():
    esperar = "--esperar" in sys.argv
    if esperar:
        # Esperar a que todas las réplicas alcancen el LSN del primario (carga detenida)
        for _ in range(30):
            datos = {n: leer(ip) for n, ip in NODOS.items()}
            lsns = {n: d[7] for n, d in datos.items() if not isinstance(d, Exception)}
            if len(set(str(v) for v in lsns.values())) == 1:
                break
            time.sleep(1)

    datos = {n: leer(ip) for n, ip in NODOS.items()}
    print(f"{'nodo':5} {'rol':8} {'cuentas':>7} {'suma':>14} {'movs':>8} {'faltan':>6}  "
          f"{'md5 cuentas':12} {'md5 movs':12} lsn")
    errores = []
    vivos = {}
    for n, d in datos.items():
        if isinstance(d, Exception):
            print(f"{n:5} NO DISPONIBLE ({str(d).strip().splitlines()[0] if str(d).strip() else type(d).__name__})")
            continue
        replica, ncuentas, suma, h_cuentas, nmovs, h_movs, faltan, lsn = d
        rol = "réplica" if replica else "PRIMARIO"
        vivos[n] = d
        print(f"{n:5} {rol:8} {ncuentas:>7} {suma:>14,.2f} {nmovs:>8} {faltan:>6}  "
              f"{(h_cuentas or '')[:12]:12} {(h_movs or '')[:12]:12} {lsn}")
        if suma != SUMA_ESPERADA:
            errores.append(f"{n}: suma de saldos {suma} != {SUMA_ESPERADA}")
        if faltan != 0:
            errores.append(f"{n}: faltan {faltan} secuencias")

    primarios = [n for n, d in vivos.items() if not d[0]]
    if len(primarios) != 1:
        errores.append(f"hay {len(primarios)} primarios: {primarios}")
    if len({(d[3], d[5]) for d in vivos.values()}) > 1:
        errores.append("los nodos NO tienen datos idénticos "
                       "(normal si la carga sigue corriendo; detenerla y usar --esperar)")

    print()
    if errores:
        print("RESULTADO: FALLA")
        for e in errores:
            print("  -", e)
        sys.exit(1)
    print(f"RESULTADO: OK. {len(vivos)} nodos con datos idénticos, suma = {SUMA_ESPERADA:,}, "
          f"sin secuencias faltantes, un solo primario.")


if __name__ == "__main__":
    main()
