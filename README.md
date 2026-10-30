# ha_db_ip: alta disponibilidad de una base de datos en 3 equipos

Clúster PostgreSQL 16 de 3 nodos con **Patroni** (failover automático), **etcd** (quórum) y **HAProxy**, todo en Docker. Funciona en macOS (Apple Silicon) y Pop!_OS/Ubuntu.

- Recibe más de 90 cambios por minuto: el generador hace 540 por minuto con los 3 nodos y 360 con uno caído.
- Siempre hay un espejo: cada `COMMIT` confirmado queda en al menos 2 equipos, gracias a la replicación síncrona.
- Si se apaga **cualquier** equipo, otro toma el papel de primario solo, en unos 20–30 s.
- Al volver, el equipo se re-sincroniza solo (`pg_rewind` o WAL).

**Documentación principal:** [`INFORME.md`](INFORME.md) ([PDF](INFORME.pdf)), el informe técnico con diseño, fundamentos y resultados, y [`MANUAL.md`](MANUAL.md) ([PDF](MANUAL.pdf)), el manual de instalación, operación y recuperación.

El plan completo, con la explicación de cada decisión, las pruebas y el guion de la demo, está en [`PLAN_ALTA_DISPONIBILIDAD.md`](PLAN_ALTA_DISPONIBILIDAD.md) (también en [PDF](PLAN_ALTA_DISPONIBILIDAD.pdf)).

**Casos límite** (qué pasa si caen dos nodos, si se duerme una laptop, si se corta la red…): [`EDGE_CASES.md`](EDGE_CASES.md).

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
./scripts/carga.sh iniciar             # generador de ESTE equipo en segundo plano (detener / estado)
./scripts/panel.sh --fondo             # panel en segundo plano en :8080 (--detener)
source scripts/env_app.sh
python app/monitor.py                  # estado en vivo en la terminal
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

## Reinstalar o reconfigurar una PC

Todo está en este repositorio salvo el `.env` de cada equipo, que tiene las IP y las 4 contraseñas. **Guarda las contraseñas en un lugar seguro**: son lo único que hay que escribir a mano.

1. **Si la PC se formateó o Tailscale se reinstaló:** Tailscale le da una IP nueva. Para conservar la anterior y no tocar nada en los otros equipos, entra a https://login.tailscale.com/admin/machines, **borra la máquina vieja** y en la nueva usa **⋯ → Edit machine IPv4** para ponerle la IP que tenía.
2. **Instalar:**
   ```bash
   git clone https://github.com/NohelEstradaP/ha_db_ip.git ~/hadb && cd ~/hadb
   ./instalar.sh
   ```
   Responde el nodo (`n1`/`n2`/`n3`), las mismas 3 IP, **`n`** a "¿Es el PRIMER equipo?" y pega las 4 contraseñas. Al final responde **S** a "¿Levantar ahora este nodo?".
3. **Listo.** `iniciar.sh` detecta que el clúster ya existe: retira de etcd el miembro viejo de ese nodo, lo vuelve a agregar y PostgreSQL se copia solo desde el primario. Termina cuando el nodo está sincronizado (unos 30 s; probado borrando todos los datos de n1).
4. **Opcional:** `./scripts/carga.sh iniciar` y `./scripts/panel.sh --fondo`.

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
| `scripts/` | Iniciar (con reincorporación automática), estado, crear BD, carga, panel, patronictl, prueba de puertos |
| `laboratorio/` | Los 3 nodos en una sola máquina |
