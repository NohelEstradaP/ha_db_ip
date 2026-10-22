#!/usr/bin/env python3
"""Generador de carga para el clúster HA.

Cada operación es una transferencia entre dos cuentas:
1 INSERT en movimientos + 2 UPDATE en cuentas = 3 cambios por transacción.
Las operaciones son idempotentes (UNIQUE generador+seq): si se cae el primario
a mitad del COMMIT se reintenta la misma seq sin riesgo de duplicarla.
"""
import argparse
import csv
import os
import random
import socket
import time
from datetime import datetime

import psycopg

CUENTAS = 100


def ahora():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def primera_linea(e):
    texto = str(e).strip()
    return texto.splitlines()[0] if texto else type(e).__name__


def conectar(dsn):
    intento = 0
    while True:
        try:
            conn = psycopg.connect(dsn, autocommit=True)
            print(f"{ahora()} conectado al primario {conn.info.host}", flush=True)
            return conn
        except psycopg.Error as e:
            intento += 1
            print(f"{ahora()} sin primario (intento {intento}): {primera_linea(e)}", flush=True)
            time.sleep(min(2.0, 0.5 * intento))


def transferir(conn, generador, seq, origen, destino, monto):
    """Aplica la transferencia. Devuelve 'ok' o 'duplicado'."""
    with conn.transaction():
        # Bloquear ambas cuentas en orden de id evita deadlocks entre generadores
        conn.execute(
            "SELECT id FROM cuentas WHERE id = ANY(%s) ORDER BY id FOR UPDATE",
            ([origen, destino],),
        )
        saldo = conn.execute(
            "SELECT saldo FROM cuentas WHERE id = %s", (origen,)
        ).fetchone()[0]
        monto = min(monto, saldo)
        fila = conn.execute(
            """INSERT INTO movimientos (generador, seq, origen, destino, monto, primario)
               VALUES (%s, %s, %s, %s, %s, %s)
               ON CONFLICT (generador, seq) DO NOTHING
               RETURNING id""",
            (generador, seq, origen, destino, monto, conn.info.host),
        ).fetchone()
        if fila is None:
            return "duplicado"
        conn.execute(
            "UPDATE cuentas SET saldo = saldo - %s, actualizado = now() WHERE id = %s",
            (monto, origen),
        )
        conn.execute(
            "UPDATE cuentas SET saldo = saldo + %s, actualizado = now() WHERE id = %s",
            (monto, destino),
        )
    return "ok"


def main():
    ap = argparse.ArgumentParser(description="Generador de carga HA")
    ap.add_argument("--tps", type=float, default=1.0,
                    help="transacciones por segundo (1.0 = 60 tx/min = 180 cambios/min)")
    ap.add_argument("--nombre", default=socket.gethostname().split(".")[0],
                    help="prefijo del generador (por defecto el hostname)")
    args = ap.parse_args()

    dsn = os.environ["HA_DSN"]
    generador = f"{args.nombre}-{datetime.now():%Y%m%d%H%M%S}"
    os.makedirs("evidencias", exist_ok=True)
    ruta_csv = os.path.join("evidencias", f"generador_{generador}.csv")

    with open(ruta_csv, "w", newline="") as archivo:
        log = csv.writer(archivo)
        log.writerow(["timestamp", "generador", "seq", "resultado",
                      "primario", "latencia_ms", "intentos"])

        print(f"{ahora()} generador {generador} a {args.tps} tx/s -> {ruta_csv}", flush=True)
        conn = conectar(dsn)
        periodo = 1.0 / args.tps
        siguiente = time.monotonic()
        seq = ok = duplicados = 0

        try:
            while True:
                seq += 1
                origen, destino = random.sample(range(1, CUENTAS + 1), 2)
                monto = random.randint(1, 500)
                intentos = 0
                t0 = time.monotonic()
                while True:
                    intentos += 1
                    try:
                        resultado = transferir(conn, generador, seq, origen, destino, monto)
                        break
                    except psycopg.Error as e:
                        print(f"{ahora()} seq={seq} intento={intentos} error: "
                              f"{type(e).__name__}: {primera_linea(e)}", flush=True)
                        try:
                            conn.close()
                        except Exception:
                            pass
                        conn = conectar(dsn)

                latencia = (time.monotonic() - t0) * 1000
                ok += resultado == "ok"
                duplicados += resultado == "duplicado"
                log.writerow([datetime.now().isoformat(timespec="milliseconds"), generador,
                              seq, resultado, conn.info.host, f"{latencia:.1f}", intentos])
                archivo.flush()
                if intentos > 1 or seq % 30 == 0:
                    print(f"{ahora()} seq={seq} {resultado} primario={conn.info.host} "
                          f"lat={latencia:.0f}ms intentos={intentos} "
                          f"(ok={ok} duplicados={duplicados})", flush=True)

                # Ritmo constante; si hubo una pausa (failover) se recupera el atraso
                siguiente += periodo
                espera = siguiente - time.monotonic()
                if espera > 0:
                    time.sleep(espera)
                elif espera < -120:
                    siguiente = time.monotonic()
        except KeyboardInterrupt:
            print(f"\n{ahora()} detenido. último seq={seq} ok={ok} duplicados={duplicados}")


if __name__ == "__main__":
    main()
