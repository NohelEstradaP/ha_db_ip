# ha_db_ip: alta disponibilidad de una base de datos en 3 equipos

Clúster PostgreSQL 16 de 3 nodos con **Patroni** (failover automático), **etcd** (quórum) y **HAProxy**, todo en Docker. Funciona en macOS (Apple Silicon) y Pop!_OS/Ubuntu.

- Recibe más de 90 cambios por minuto: el generador hace 540 por minuto con los 3 nodos y 360 con uno caído.
- Siempre hay un espejo: cada `COMMIT` confirmado queda en al menos 2 equipos, gracias a la replicación síncrona.
- Si se apaga **cualquier** equipo, otro toma el papel de primario solo, en unos 20–30 s.
- Al volver, el equipo se re-sincroniza solo (`pg_rewind` o WAL).

El plan completo, con la explicación de cada decisión, las pruebas y el guion de la demo, está en [`PLAN_ALTA_DISPONIBILIDAD.md`](PLAN_ALTA_DISPONIBILIDAD.md) (también en [PDF](PLAN_ALTA_DISPONIBILIDAD.pdf)).

**¿Qué falta y por dónde empiezo?** Ver [`GUIA_PENDIENTES.md`](GUIA_PENDIENTES.md) ([PDF](GUIA_PENDIENTES.pdf)): checklist y pasos en orden para dejar todo funcionando en los 3 equipos.

## Instalación en los 3 equipos

```bash
git clone https://github.com/NohelEstradaP/ha_db_ip.git ~/hadb
cd ~/hadb
./instalar.sh          # con Tailscale (sirve en la misma red o en redes distintas)
# ./instalar.sh --lan  # alternativa: solo red local, sin Tailscale
```

El instalador:
1. Instala lo necesario: Docker, Tailscale, git, Python y jq.
2. Desactiva el reposo del equipo.
3. Pregunta qué nodo es el equipo (`n1`, `n2` o `n3`) y las IP de los 3.
4. Genera el archivo `.env`. En el primer equipo crea las contraseñas; en los otros dos se pegan las mismas.
5. Prepara Python y construye las imágenes de Docker.

Se puede volver a correr sin problema: salta lo que ya está hecho.

## Puesta en marcha

```bash
./scripts/probar_puertos.sh   # conectividad entre los 3 equipos
./scripts/iniciar.sh          # en los 3 equipos
./scripts/crear_bd.sh         # UNA vez, en cualquiera
./scripts/estado.sh           # quién es primario, réplicas, etcd
```

## Carga, monitoreo e integridad

```bash
source scripts/env_app.sh
python app/generador.py --nombre n1    # en cada equipo, con su nombre
python app/monitor.py                  # estado en vivo y cambios por minuto
python app/verificar.py --esperar      # con la carga detenida: compara los 3 nodos
```

## Panel en tiempo real

```bash
./scripts/panel.sh                     # abrir http://localhost:8080
```
Muestra en vivo:
- el rol de cada nodo, el lag, el timeline, etcd y HAProxy;
- los cambios por minuto (con la línea del mínimo de 90) y la suma de saldos;
- los eventos (caídas, failover con su duración, re-sincronización) y los últimos movimientos.

Funciona sin internet. Desde otro equipo o un celular se abre con `http://<IP del equipo>:8080`.

Cada tarjeta de nodo tiene un botón **★ Hacer primario** (pide confirmación). Con replicación síncrona Patroni solo promueve a la réplica síncrona; si eliges otro nodo, el panel hace los cambios intermedios solo y muestra el avance. Para un panel que solo mire, sin botones: `./scripts/panel.sh --solo-lectura`.

## Practicar en un solo equipo

`laboratorio/` levanta los 3 nodos en una sola máquina, con la misma configuración, para ensayar fallas sin las 3 PC:

```bash
./laboratorio/lab.sh iniciar
./laboratorio/lab.sh carga
./laboratorio/lab.sh panel              # http://localhost:18080
./laboratorio/lab.sh apagar n1          # o: detener n1 / aislar n1
./laboratorio/lab.sh encender n1
./laboratorio/lab.sh parar-carga && ./laboratorio/lab.sh verificar
./laboratorio/lab.sh destruir
```

## Estructura

| Ruta | Contenido |
|------|-----------|
| `instalar.sh` | Prepara un equipo como nodo |
| `docker-compose.yml`, `.env.example` | Servicios del nodo (idénticos en los 3; solo cambia `.env`) |
| `patroni/` | Imagen PostgreSQL 16 + Patroni y su configuración |
| `haproxy/` | Puerto 5000 → primario, 5001 → réplicas, 7000 → panel |
| `sql/esquema.sql` | Cuentas y movimientos (la suma de saldos siempre es 1,000,000) |
| `app/` | Generador de carga, monitor, verificador de integridad y panel web (`panel.py`) |
| `scripts/` | Iniciar, estado, crear BD, panel, patronictl, prueba de puertos |
| `laboratorio/` | Los 3 nodos en una sola máquina |
