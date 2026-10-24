#!/usr/bin/env python3
"""Panel web en tiempo real del clúster.

Consulta cada segundo a los 3 nodos (API de Patroni, etcd, HAProxy y PostgreSQL)
y al primario (vía HA_DSN) y sirve una página que se actualiza sola (consulta /api/estado cada segundo):
    http://<IP de este equipo>:8080
Solo lee: no cambia nada en el clúster.
"""
import argparse
import csv
import io
import json
import os
import threading
import time
import urllib.request
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

NODOS = {"n1": os.environ["N1_IP"], "n2": os.environ["N2_IP"], "n3": os.environ["N3_IP"]}
IP_A_NODO = {ip: n for n, ip in NODOS.items()}
CLAVE = os.environ["APP_PASSWORD"]
DSN = os.environ["HA_DSN"]
SUMA_ESPERADA = 1000000
INTERVALO = 1.0
VIGENCIA = 6.0          # segundos sin respuesta para dar un nodo por caído
VENTANA_SERIE = 600     # 10 minutos de historia en la gráfica
BALDE = 10              # la gráfica agrupa en ventanas de 10 s
HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "panel.html")

OPCIONES_TCP = dict(connect_timeout=2, keepalives=1, keepalives_idle=2,
                    keepalives_interval=1, keepalives_count=2, tcp_user_timeout=3000)


def ahora():
    return time.time()


def hora(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def primera_linea(e):
    texto = str(e).strip()
    return texto.splitlines()[0] if texto else type(e).__name__


def http_json(url, timeout=1.5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def haproxy_primario(ip):
    """Nodo al que el HAProxy de `ip` está mandando las escrituras (puerto 5000)."""
    with urllib.request.urlopen(f"http://{ip}:7000/;csv", timeout=1) as r:
        texto = r.read().decode().lstrip("# ")
    for fila in csv.DictReader(io.StringIO(texto)):
        if fila.get("pxname") == "primario" and fila.get("status", "").startswith("UP") \
                and fila.get("svname") in NODOS:
            return fila["svname"]
    return None


class Nodo(threading.Thread):
    """Sondea un nodo: Patroni, etcd, HAProxy y su PostgreSQL directamente."""

    def __init__(self, nombre, ip):
        super().__init__(daemon=True)
        self.nombre, self.ip = nombre, ip
        self.conn = None
        self.estado = {"visto": 0}

    def consultar_bd(self):
        try:
            if self.conn is None or self.conn.closed:
                self.conn = psycopg.connect(
                    host=self.ip, port=5432, dbname="hadb", user="app", password=CLAVE,
                    autocommit=True, **OPCIONES_TCP)
            fila = self.conn.execute(
                "SELECT pg_is_in_recovery(), (SELECT count(*) FROM movimientos),"
                " (SELECT sum(saldo) FROM cuentas)").fetchone()
            return {"replica": fila[0], "movimientos": fila[1],
                    "suma": float(fila[2]) if fila[2] is not None else None}
        except psycopg.Error as e:
            try:
                if self.conn is not None:
                    self.conn.close()
            except Exception:
                pass
            self.conn = None
            return {"error": primera_linea(e)}

    def run(self):
        while True:
            inicio = ahora()
            nuevo = {}
            try:
                nuevo["patroni"] = http_json(f"http://{self.ip}:8008/patroni")
            except Exception:
                nuevo["patroni"] = None
            try:
                nuevo["etcd"] = http_json(f"http://{self.ip}:2379/health", timeout=1).get("health") == "true"
            except Exception:
                nuevo["etcd"] = False
            try:
                nuevo["haproxy"] = haproxy_primario(self.ip)
            except Exception:
                nuevo["haproxy"] = "sin respuesta"
            if nuevo["patroni"] is not None:
                nuevo["bd"] = self.consultar_bd()
                nuevo["visto"] = ahora()
            else:
                nuevo["bd"] = None
                nuevo["visto"] = self.estado.get("visto", 0)
            self.estado = nuevo
            time.sleep(max(0.0, INTERVALO - (ahora() - inicio)))


class Primario(threading.Thread):
    """Escribe por el mismo camino que la aplicación (HA_DSN) y lee las métricas de carga."""

    def __init__(self):
        super().__init__(daemon=True)
        self.conn = None
        self.estado = {"disponible": False, "visto": 0}

    def run(self):
        while True:
            inicio = ahora()
            try:
                if self.conn is None or self.conn.closed:
                    self.conn = psycopg.connect(DSN, autocommit=True, connect_timeout=2)
                c = self.conn
                tx_min, total, suma = c.execute(
                    "SELECT count(*) FILTER (WHERE creado > now() - interval '60 seconds'), count(*),"
                    " (SELECT sum(saldo) FROM cuentas) FROM movimientos").fetchone()
                baldes = c.execute(
                    "SELECT (floor(extract(epoch FROM creado) / %s) * %s)::bigint, count(*)"
                    " FROM movimientos WHERE creado > now() - make_interval(secs => %s)"
                    " GROUP BY 1 ORDER BY 1", (BALDE, BALDE, VENTANA_SERIE)).fetchall()
                generadores = c.execute(
                    "SELECT generador, count(*), max(seq), max(seq) - count(*),"
                    " extract(epoch FROM now() - max(creado))"
                    " FROM movimientos GROUP BY generador"
                    " ORDER BY max(creado) DESC LIMIT 8").fetchall()
                recientes = c.execute(
                    "SELECT generador, seq, origen, destino, monto, primario,"
                    " extract(epoch FROM creado)"
                    " FROM movimientos ORDER BY id DESC LIMIT 10").fetchall()
                ahora_bd = c.execute("SELECT extract(epoch FROM now())").fetchone()[0]
                self.estado = {
                    "disponible": True,
                    "visto": ahora(),
                    "host": c.info.host,
                    "nodo": IP_A_NODO.get(c.info.host, c.info.host),
                    "tx_min": tx_min,
                    "total": total,
                    "suma": float(suma) if suma is not None else None,
                    "serie": serie(baldes, float(ahora_bd)),
                    "generadores": [
                        {"nombre": g, "filas": n, "ultimo_seq": s, "faltan": f,
                         "hace": round(float(h), 1)} for g, n, s, f, h in generadores],
                    "recientes": [
                        {"generador": g, "seq": s, "origen": o, "destino": d, "monto": float(m),
                         "primario": IP_A_NODO.get(p, p), "t": float(t)}
                        for g, s, o, d, m, p, t in recientes],
                }
            except psycopg.Error as e:
                try:
                    if self.conn is not None:
                        self.conn.close()
                except Exception:
                    pass
                self.conn = None
                anterior = dict(self.estado)
                anterior.update(disponible=False, error=primera_linea(e))
                self.estado = anterior
            time.sleep(max(0.0, INTERVALO - (ahora() - inicio)))


def serie(baldes, ahora_bd):
    """Cambios/min equivalentes por ventana de BALDE s (se descarta la ventana en curso)."""
    conteo = {int(b): n for b, n in baldes}
    fin = int(ahora_bd // BALDE) * BALDE
    puntos = []
    for b in range(fin - VENTANA_SERIE, fin, BALDE):
        tx = conteo.get(b, 0)
        puntos.append({"t": b, "cambios_min": tx * 3 * (60 // BALDE)})
    return puntos


def consultar_cluster():
    """Roles según Patroni (/cluster) desde el primer nodo que responda."""
    for ip in NODOS.values():
        try:
            return http_json(f"http://{ip}:8008/cluster", timeout=1)
        except Exception:
            continue
    return None


class Agregador(threading.Thread):
    """Junta todo en una foto por segundo y detecta eventos (caídas, failover, re-sincronización)."""

    def __init__(self, nodos, primario):
        super().__init__(daemon=True)
        self.nodos, self.primario = nodos, primario
        self.eventos = deque(maxlen=120)
        self.foto = "{}"
        self.previo = None
        self.sin_primario_desde = None
        self.hubo_primario = False   # el primer primario al arrancar no cuenta como failover
        self.ultimo_failover = None
        self.marcas = deque(maxlen=20)   # momentos de failover para la gráfica
        self.regreso = {}                # nodo -> momento en que volvió (para no repetir avisos al reincorporarse)
        self.conocidos = set()           # nodos que ya se vieron vivos alguna vez
        self.evento("info", "Panel iniciado")

    def evento(self, tipo, texto):
        self.eventos.appendleft({"t": ahora(), "hora": hora(ahora()), "tipo": tipo, "texto": texto})

    def run(self):
        while True:
            inicio = ahora()
            try:
                self.tick()
            except Exception as e:      # el panel nunca debe morir por un dato raro
                self.evento("error", f"Error interno del panel: {primera_linea(e)}")
            time.sleep(max(0.0, INTERVALO - (ahora() - inicio)))

    def tick(self):
        t = ahora()
        cluster = consultar_cluster()
        miembros = {m.get("name"): m for m in (cluster or {}).get("members", [])}
        p = self.primario.estado

        nodos = []
        for nodo in self.nodos:
            e = nodo.estado
            vivo = e.get("patroni") is not None and t - e.get("visto", 0) < VIGENCIA
            m = miembros.get(nodo.nombre, {})
            rol_patroni = (e.get("patroni") or {}).get("role")
            rol = "caido"
            if vivo:
                rol = {"leader": "primario", "sync_standby": "sincrona", "replica": "replica",
                       "standby_leader": "replica"}.get(m.get("role"))
                if rol is None:
                    rol = "primario" if rol_patroni in ("primary", "master") else "replica"
            lag = m.get("lag")
            nodos.append({
                "nombre": nodo.nombre,
                "ip": nodo.ip,
                "vivo": vivo,
                "rol": rol,
                "estado": m.get("state") or (e.get("patroni") or {}).get("state") or "sin respuesta",
                "timeline": m.get("timeline") or (e.get("patroni") or {}).get("timeline"),
                "lag": lag if isinstance(lag, (int, float)) else None,
                "etcd": e.get("etcd", False),
                "haproxy": e.get("haproxy"),
                "bd": e.get("bd"),
                "hace": round(t - e["visto"], 1) if e.get("visto") else None,
            })

        disponible = p.get("disponible", False) and t - p.get("visto", 0) < VIGENCIA
        primario_nodo = p.get("nodo") if disponible else None
        vivos = sum(n["vivo"] for n in nodos)
        hay_sync = any(n["rol"] == "sincrona" and n["vivo"] for n in nodos)
        timeline = max([n["timeline"] for n in nodos if n["vivo"] and n["timeline"]] or [None]) \
            if vivos else None

        self.detectar_eventos(nodos, disponible, primario_nodo, timeline, p, t)

        if not disponible:
            estado = ("critico", "Sin primario: escrituras en pausa")
        elif vivos == 3 and hay_sync:
            estado = ("sano", "Sano: 3 nodos, réplica síncrona activa")
        elif vivos == 3:
            estado = ("aviso", "Asignando réplica síncrona")
        else:
            estado = ("degradado", f"Degradado: {vivos} de 3 nodos (sigue funcionando)")

        suma = p.get("suma")
        self.foto = json.dumps({
            "generado": t,
            "hora": hora(t),
            "estado": {"nivel": estado[0], "texto": estado[1]},
            "nodos": nodos,
            "primario": {
                "disponible": disponible,
                "nodo": primario_nodo,
                "ip": p.get("host") if disponible else None,
                "error": None if disponible else p.get("error"),
                "sin_primario_s": round(t - self.sin_primario_desde, 1) if self.sin_primario_desde else None,
            },
            "carga": {
                "tx_min": p.get("tx_min"),
                "cambios_min": None if p.get("tx_min") is None else p["tx_min"] * 3,
                "minimo": 90,
                "total": p.get("total"),
                "datos_de_hace": round(t - p["visto"], 1) if p.get("visto") else None,
            },
            "integridad": {
                "suma": suma,
                "esperada": SUMA_ESPERADA,
                "ok": suma is not None and abs(suma - SUMA_ESPERADA) < 0.005,
                "faltan": sum(g["faltan"] for g in p.get("generadores", [])) if p.get("generadores") else 0,
            },
            "timeline": timeline,
            "ultimo_failover": self.ultimo_failover,
            "serie": p.get("serie", []),
            "marcas": list(self.marcas),
            "generadores": p.get("generadores", []),
            "recientes": p.get("recientes", []),
            "eventos": list(self.eventos)[:40],
        })

    def detectar_eventos(self, nodos, disponible, primario_nodo, timeline, p, t):
        previo = self.previo
        self.previo = {"nodos": {n["nombre"]: n for n in nodos}, "disponible": disponible,
                       "primario": primario_nodo, "timeline": timeline,
                       "suma_ok": p.get("suma") is None or abs(p["suma"] - SUMA_ESPERADA) < 0.005}
        if previo is None:
            if not disponible:
                self.sin_primario_desde = t
            return

        nombres_rol = {"primario": "PRIMARIO", "sincrona": "réplica síncrona", "replica": "réplica"}
        for n in nodos:
            antes = previo["nodos"][n["nombre"]]
            # Al reincorporarse (pg_rewind, reinicio de PostgreSQL) la API puede callar unos segundos:
            # durante 45 s después de volver no se repiten los avisos de caída/regreso.
            reincorporandose = t - self.regreso.get(n["nombre"], 0) < 45
            if antes["vivo"] and not n["vivo"]:
                if not reincorporandose:
                    self.evento("caida", f"{n['nombre']} dejó de responder (apagado o sin red)")
            elif not antes["vivo"] and n["vivo"] and n["nombre"] not in self.conocidos:
                self.evento("info", f"{n['nombre']} en línea ({n['estado']})")
            elif not antes["vivo"] and n["vivo"]:
                if not reincorporandose:
                    self.regreso[n["nombre"]] = t
                    self.evento("recupera", f"{n['nombre']} volvió a responder, reincorporándose")
            elif n["vivo"] and antes["rol"] != n["rol"] and n["rol"] in nombres_rol:
                self.evento("rol", f"{n['nombre']} ahora es {nombres_rol[n['rol']]}")
            if n["vivo"] and antes["vivo"] and antes["estado"] != "streaming" and n["estado"] == "streaming" \
                    and n["rol"] != "primario":
                self.evento("recupera", f"{n['nombre']} sincronizado (streaming)")

        if previo["disponible"] and not disponible:
            self.sin_primario_desde = t
            self.evento("caida", "Sin primario: las escrituras quedaron en pausa")
        elif not previo["disponible"] and disponible:
            if not self.hubo_primario:
                self.evento("info", f"Primario disponible: {primario_nodo}")
            elif self.sin_primario_desde is not None:
                duracion = round(t - self.sin_primario_desde, 1)
                self.ultimo_failover = {"segundos": duracion, "hora": hora(t), "t": t, "nuevo": primario_nodo}
                self.marcas.append({"t": t, "texto": f"failover {duracion} s"})
                self.evento("failover", f"Escrituras restablecidas en {primario_nodo} tras {duracion} s")
            self.sin_primario_desde = None
        elif disponible and previo["primario"] and primario_nodo != previo["primario"]:
            self.evento("failover", f"El primario cambió de {previo['primario']} a {primario_nodo}")

        self.conocidos.update(n["nombre"] for n in nodos if n["vivo"])
        if disponible:
            self.hubo_primario = True
        if timeline and previo["timeline"] and timeline > previo["timeline"]:
            self.evento("rol", f"Timeline {previo['timeline']} → {timeline} (nueva historia tras promover)")
        suma_ok = self.previo["suma_ok"]
        if previo["suma_ok"] and not suma_ok:
            self.evento("error", f"¡La suma de saldos cambió! {p.get('suma')}")


class Manejador(BaseHTTPRequestHandler):
    agregador = None

    def log_message(self, *args):
        pass

    def enviar(self, codigo, tipo, cuerpo):
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(HTML, "rb") as f:
                self.enviar(200, "text/html; charset=utf-8", f.read())
        elif self.path == "/api/estado":
            self.enviar(200, "application/json", self.agregador.foto.encode())
        else:
            self.enviar(404, "text/plain", b"no encontrado")


def main():
    ap = argparse.ArgumentParser(description="Panel web en tiempo real del clúster")
    ap.add_argument("--puerto", type=int, default=8080)
    args = ap.parse_args()

    nodos = [Nodo(n, ip) for n, ip in NODOS.items()]
    primario = Primario()
    for hilo in nodos + [primario]:
        hilo.start()
    agregador = Agregador(nodos, primario)
    agregador.start()

    Manejador.agregador = agregador
    servidor = ThreadingHTTPServer(("0.0.0.0", args.puerto), Manejador)
    servidor.daemon_threads = True
    print(f"Panel en http://localhost:{args.puerto}  (desde otros equipos: http://<IP de este equipo>:{args.puerto})",
          flush=True)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("\npanel detenido")


if __name__ == "__main__":
    main()
