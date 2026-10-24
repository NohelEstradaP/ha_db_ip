# Casos límite (edge cases) del clúster

Qué pasa en situaciones poco comunes, si ya se probó y qué hacer.

**Estado:** ✔ probado en las máquinas reales · 🧪 probado en el laboratorio · ⚠ riesgo a vigilar · ➖ esperado / fuera de alcance

---

## 0. Los que más importan para la demo

| # | Caso | Qué pasa | Qué hacer |
|---|------|----------|-----------|
| D1 | **Solo hay generador en un equipo y apagan ese equipo** | La carga cae a **0 cambios/min**. El clúster sigue sano, pero parece que falla R1 (≥ 90/min) | Correr un generador en **al menos 2 equipos** (lo ideal: los 3). Con uno apagado quedan ≥ 120 tx/min |
| D2 | **Se apaga el equipo que proyecta el panel** | Se pierde la vista justo durante el failover | Abrir el panel en 2 equipos, o verlo desde un celular por `http://<IP>:8080` |
| D3 | **El panel corre en el nodo que queda aislado (partición)** | Ese panel ve "Sin primario" y los otros nodos caídos, aunque el resto del clúster sí tenga primario. En P4 marcó 50,6 s, cuando el failover real fue de 22 s | Interpretar el panel del lado con mayoría. Para medir la partición, usar `pctl history` |
| D4 | **Una laptop se duerme o se cierra la tapa** | Para el clúster es igual a apagarla. Al despertar se reincorpora sola | `caffeinate -dimsu` en las Mac, suspensión desactivada en Pop!_OS y no cerrar tapas |
| D5 | **Botón "Hacer primario" pulsado desde dos paneles a la vez** | Cada panel tiene su propio candado, así que dos cadenas de switchover pueden cruzarse y el primario final puede no ser el esperado. Patroni rechaza los switchover simultáneos, pero no las cadenas encadenadas | Usar los botones desde **un solo** panel. Los demás, con `./scripts/panel.sh --solo-lectura` |
| D6 | **Actualizaciones automáticas durante la demo** (Docker Desktop, OrbStack, `apt`) | Reinician Docker y el nodo cae unos segundos | Desactivar las actualizaciones automáticas y no aceptar ventanas de "Update" ese día |
| D7 | **La red del lugar bloquea UDP o aísla clientes** | Tailscale pasa por relay (DERP, más latencia) o los equipos no se ven | Probar en el lugar antes. Respaldo: hotspot o router propio |

---

## 1. Caídas de nodos

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 1.1 | Se cae el primario de golpe | La réplica síncrona asume en unos 26 s y los clientes reintentan | ✔ P3 (26,1 s) | Nada |
| 1.2 | El primario se detiene limpio (reinicio de Docker o de la PC) | Patroni suelta el liderazgo y la síncrona asume en unos 3–5 s | ✔ P9 (3,0 s) y caída real de n2 (5,0 s) | Nada |
| 1.3 | Se cae una réplica | Sin interrupción. Si era la síncrona, Patroni nombra síncrona a la otra | ✔ P2 (0 s) | Nada |
| 1.4 | El nodo caído vuelve | Si era réplica, recupera el WAL atrasado. Si era primario, `pg_rewind` y queda como réplica | ✔ P3, P7 | Nada |
| 1.5 | Un nodo está caído mucho tiempo | Recupera con WAL mientras exista (`wal_keep_size` 1 GB + slots). Si ya no existe, queda en `start failed` | ✔ P7 (10 min, 5 s) · ⚠ más de muchas horas | `./scripts/pctl.sh reinit hadb <nodo> --force` |
| 1.6 | `pg_rewind` falla al volver el primario viejo | El nodo queda en `start failed` | ⚠ no ocurrió | `reinit` (copia completa desde el primario) |
| 1.7 | **Dos nodos caídos a la vez** | Sin quórum de etcd (1 de 3): el nodo restante se pone en **solo lectura**. Es lo correcto, porque protege la integridad | ➖ fuera de alcance (3 nodos toleran 1 falla) | Encender uno de los dos; el clúster se recupera solo |
| 1.8 | Caídas encadenadas: cae el primario y, antes de que vuelva, cae el nuevo primario | Queda 1 nodo: sin quórum y en solo lectura. No se pierden datos, porque la réplica síncrona tenía todo | ➖ | Igual que 1.7 |
| 1.9 | Los 3 equipos se apagan y se encienden | Al volver, Patroni solo deja ser líder a un nodo que estaba al día (estado síncrono guardado en etcd) | ⚠ no probado | Encender primero el que era primario; los otros se unen solos |
| 1.10 | Muere solo el contenedor de etcd de un nodo | Patroni usa los etcd de los otros nodos y PostgreSQL sigue | ⚠ no probado | `docker compose up -d etcd` |
| 1.11 | Docker se reinicia en un nodo | Los contenedores vuelven solos (`restart: unless-stopped`) | ✔ caída real de n2 | En la Mac: Docker Desktop u OrbStack con "Start at login" |
| 1.12 | Disco lleno en un nodo | PostgreSQL se detiene en ese nodo. Si era el primario, hay failover | ⚠ no probado | Liberar espacio; `reinit` si quedó dañado |

## 2. Red

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 2.1 | El primario pierde la red y sigue encendido | Se degrada solo a los ~11 s y el otro lado promueve a los ~22 s. **Nunca hay dos primarios** | ✔ P4 | Nada; al reconectar vuelve como réplica |
| 2.2 | Una réplica pierde la red | Sin interrupción; al volver se pone al día | 🧪 | Nada |
| 2.3 | Los 3 quedan aislados entre sí (se cae el router) | Ningún lado tiene mayoría: todos en solo lectura | ➖ | Restablecer la red; se recupera solo |
| 2.4 | Partición asimétrica (A ve a B, B ve a C, A no ve a C) | etcd (Raft) decide con la mayoría que se comunique. Puede haber elecciones repetidas | ⚠ raro | Revisar la conectividad con `tailscale ping` |
| 2.5 | Red lenta o con cortes cortos (relay DERP, WiFi de universidad) | `ttl` 20 s y los tiempos de etcd toleran segundos de latencia. Cortes de más de unos 20 s provocan failover | ⚠ | Preferir cable o hotspot; ver `tailscale netcheck` |
| 2.6 | Cambia la IP LAN de un nodo (modo `--lan`) | etcd no arranca: guarda las IP de sus pares | ➖ con Tailscale no pasa | Plan §6.4 (reconstruir etcd) |
| 2.7 | Tailscale cierra la sesión o expira la llave | El nodo sale de la red = partición | ✔ expiración desactivada en los 3 | No cerrar sesión en Tailscale |
| 2.8 | Se cae internet pero la LAN sigue | Las conexiones Tailscale ya establecidas suelen seguir un rato; equipos nuevos no se conectan | ⚠ | Conectar todo antes de la demo |
| 2.9 | **Las IP en `.env` no coinciden entre nodos** | etcd no forma quórum o un nodo no se une | ✔ ocurrió (IP de n2/n3 cruzadas en la Mac) | `grep _IP .env` en los 3: deben ser idénticas |

## 3. Datos e integridad

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 3.1 | La conexión se cae durante un `COMMIT` | El cliente no sabe si se guardó. Reintenta la misma `seq` y `ON CONFLICT` evita duplicarla | ✔ 8 reintentos, 0 duplicados, 0 perdidas | Nada |
| 3.2 | El primario cae con transacciones sin replicar | Con replicación síncrona no se confirmaron al cliente. `pg_rewind` las descarta y el cliente las reintenta | ✔ P3 / P4 | Nada |
| 3.3 | Saltos en `movimientos.id` tras un failover | Normal: las secuencias reservan valores por bloques de 32 | ➖ | Medir la integridad por `(generador, seq)`, no por `id` |
| 3.4 | Leer de una réplica (puerto 5001) justo después de escribir | Puede no verse aún lo último (lag de milisegundos) | ➖ | Para leer lo propio, usar el primario (5000 o `HA_DSN`) |
| 3.5 | Los hashes de `verificar.py` difieren con carga activa | Normal: los nodos van milisegundos atrás | ✔ | Detener los generadores y usar `--esperar` |
| 3.6 | Dos generadores con el mismo `--nombre` arrancados en el mismo segundo | Comparten el identificador: uno ve "duplicado" y deja huecos aparentes | ⚠ | Nombres distintos por equipo (`n1`, `n2`, `n3`) |
| 3.7 | Réplica asíncrona muy atrasada (más de 1 MB) | Patroni no la promueve (`maximum_lag_on_failover`) | ➖ protección | Nada |
| 3.8 | Diferencia de arquitectura (ARM ↔ x86) | Replica bien en ambas direcciones (misma imagen Debian, `C.UTF-8`) | ✔ | No mezclar versiones de imagen entre nodos |
| 3.9 | Corrupción de una página de datos | `data-checksums` la detecta y da error al leer | ⚠ no probado | `reinit` del nodo afectado |

## 4. Aplicación y clientes

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 4.1 | El generador queda del lado aislado de una partición | No puede escribir hasta reconectar (56,9 s en P4). Es lo correcto: el lado en minoría no escribe | ✔ | Tener generadores también del otro lado |
| 4.2 | Pausa del primario de más de 120 s | El generador deja de recuperar el atraso (para no saturar) y ese minuto puede quedar bajo 90 | ⚠ | Solo pasa con 2 caídas o una red rota |
| 4.3 | Pico de carga justo después de un failover | El generador recupera lo atrasado: hay un pico en la gráfica | ✔ | Normal; explicarlo en la demo |
| 4.4 | Detener un generador lanzado en segundo plano | Ignora Ctrl+C (SIGINT) | ✔ ocurrió | `pkill -TERM -f app/generador.py` |
| 4.5 | Un cliente usa el HAProxy de un nodo que se apaga | Ese cliente pierde la conexión | ➖ | Usar `HA_DSN` (varios hosts) o el HAProxy de otro nodo |
| 4.6 | Conexión muerta sin cierre (cable desconectado) | Se detecta en unos 10 s por `keepalives` y `tcp_user_timeout` | ✔ | Nada |
| 4.7 | Transacción larga durante un switchover | Se aborta; el cliente debe reintentar | ➖ | Los generadores ya reintentan |

## 5. Panel web

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 5.1 | "Hacer primario" hacia un nodo que no es la síncrona | Hace 2 pasos solo (por la síncrona) | ✔ 22,3 s | Nada |
| 5.2 | "Hacer primario" con un nodo caído | Solo permite elegir la réplica síncrona | ✔ (validación) | — |
| 5.3 | Se reinicia el panel | Pierde el historial de eventos y las marcas de failover (están en memoria); la gráfica se reconstruye desde la BD | ➖ | Para el informe, usar `pctl history` y los CSV |
| 5.4 | Sin generadores o carga recién iniciada | Muestra "⏸ sin carga" o "⏳ midiendo" en lugar de "✕ bajo" | ✔ | — |
| 5.5 | Al reincorporarse un nodo, la API de Patroni no responde unos segundos | Se agrupan los avisos para no repetir "volvió / dejó de responder" | 🧪 | — |
| 5.6 | Cualquiera en la red de Tailscale puede usar el botón | No tiene autenticación | ⚠ | `--solo-lectura` en paneles compartidos |

## 6. Plataforma y operación

| # | Caso | Qué pasa | Estado | Qué hacer |
|---|------|----------|--------|-----------|
| 6.1 | Puertos 5000/7000 ocupados en macOS | Los usa el Receptor AirPlay | ✔ ocurrió | *Ajustes → General → AirDrop y Handoff → Receptor AirPlay* apagado |
| 6.2 | Mac con OrbStack en lugar de Docker Desktop | Funciona igual | ✔ n3 | "Start at login" en OrbStack |
| 6.3 | `pip` corta la descarga en una red lenta | Timeout a los 15 s | ✔ ocurrió | El instalador ya usa `--timeout 120 --retries 10` |
| 6.4 | Proxy de la red bloquea los repositorios de Debian (403) | Falla la construcción de la imagen de Patroni | ✔ ocurrió | Cambiar de red y volver a correr el instalador |
| 6.5 | Contraseñas distintas entre nodos | `password authentication failed` y la réplica no se une | ⚠ | Las 4 contraseñas iguales en los 3 `.env`, luego `reinit` |
| 6.6 | Se borra el volumen de etcd de **un** nodo (o se reinstala la PC) | Si arrancara como clúster nuevo chocaría (`cluster ID mismatch`). **`iniciar.sh` lo resuelve solo**: retira el miembro viejo, lo vuelve a agregar y arranca como `existing` | ✔ automatizado (probado 2 veces en n1) | `./scripts/iniciar.sh` |
| 6.7 | `docker compose down -v` en un nodo | Borra sus datos; con `./scripts/iniciar.sh` vuelve solo: etcd como en 6.6 y PostgreSQL se copia desde el primario (24 s en la prueba) | ✔ automatizado | Nunca en el **primario** sin antes moverlo (botón ★ del panel) |
| 6.11 | Una PC reinstalada recibe otra IP de Tailscale | Las IP del clúster ya no coinciden | ⚠ | Tailscale admin: borrar la máquina vieja y **Edit machine IPv4** en la nueva con la IP anterior |
| 6.8 | Relojes desincronizados entre equipos | No afecta el failover (etcd usa sus propios tiempos), pero sí las horas mostradas | ⚠ | NTP activado en los 3 |
| 6.9 | Usuario de Pop!_OS fuera del grupo `docker` | `docker` pide `sudo` | ✔ | Cerrar sesión y volver a entrar; los scripts usan `sudo` si hace falta |
| 6.10 | Correr el laboratorio y el clúster real en la misma Mac | No chocan los puertos (17000/18080 contra los reales), pero suman memoria | ➖ | `./laboratorio/lab.sh destruir` cuando no se use |
