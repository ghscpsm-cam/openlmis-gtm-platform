# OpenLMIS GUA Platform

Paraguas institucional para el MSPAS: **un solo comando `./platform`** que orquesta OpenLMIS en
tres capas. Pensado para que el equipo use siempre el mismo punto de entrada sin recordar YAMLs,
variables, redes ni comandos de Docker.

> Capa 1 (este repo) = plataforma/infra + backup/restore/reset. Capa 2 = `openlmis-seeder`
> (datos maestros). Capa 3 = `openlmis-importer` (transacciones, diferida). Ver `PLAN.md`.

## Modelo: orquesta el ref-distro existente

En dev, platform **no trae su propio compose**: invoca el `docker-compose` del ref-distro que ya
corre en `REFDISTRO_DIR` (`/opt/openlmis-ref-distro`), y agrega encima seed / backup / restore /
reset. Así no duplica ni reemplaza el deployment actual.

Platform también carga un override versionado (`overrides/openlmis-ref-distro.yml`) encima del
compose del ref-distro. Esto permite repetir ajustes operacionales, como memoria/CPU de
`referencedata`, y fijar las imágenes GTM sin editar a mano cada servidor.

## Uso

```bash
./platform up dev                 # levanta OpenLMIS y espera que responda
./platform status dev             # estado de servicios + OpenLMIS
./platform seed dev               # siembra datos maestros (capa 2)
./platform db-fixes dev           # aplica fixes SQL idempotentes de plataforma
./platform backup dev             # pg_dump → backups/
./platform restore dev backups/dev_20260622-1200.dump --confirm
./platform baseline dev           # captura el baseline limpio (1 vez, pg_dump)
./platform reset dev --confirm    # restaura baseline LIMPIO, NO siembra (~2.6 min)
./platform down dev               # detiene servicios (sin borrar datos)
```

`<env>` ∈ `{dev, test}` (prod no permitido). Los comandos destructivos exigen `--confirm`.

## Pruebas en limpio (`reset`) — baseline-por-dump (rápido y confiable)

Flujo recomendado para iterar en dev (**~2.6 min**, probado):

1. **Una sola vez** — llevá OpenLMIS al estado "limpio" que quieras y capturalo:
   `platform baseline dev` (es un `pg_dump`, segundos). Ese dump queda en `baselines/<env>_baseline.dump`.
2. **Cada vez que quieras limpio** — `platform reset dev --confirm`: restaura el baseline y deja
   OpenLMIS **completamente limpio** (NO siembra). Hace un backup de seguridad automático antes.
3. **Cuando quieras datos** — `platform seed dev` (manual, aparte): cargás el set que quieras.

El costo de ~2.6 min es casi todo el **reinicio de los servicios de OpenLMIS** (inherente; el
`pg_restore` es de segundos). El procedimiento manual equivalente tiene el mismo costo.

> ⚠️ **`baseline-rebuild` (migración fresca desde cero) NO se recomienda**: en este deployment es
> lento (~40 min) y frágil (la migración inicial de OpenLMIS choca con obstáculos del entorno —
> postgis y otros). Para "limpio rápido" usá un **baseline-por-dump** (`baseline` + `reset`),
> no la migración fresca. El dump de postgres es un *bind mount* (`./data`), por eso `down -v`
> no lo vacía.

> `backup`/`restore` son la herramienta general de snapshot/recuperación de la BD (pg_dump/pg_restore).

## Fixes de plataforma

`platform` aplica fixes SQL idempotentes desde `db-fixes/*.sql`. Se ejecutan automáticamente después
de `up`, `seed`, `restore`, `reset` y `baseline-rebuild`; también se pueden correr manualmente:

```bash
./platform db-fixes dev
```

Cada archivo SQL se ejecuta por separado para soportar operaciones como `CREATE INDEX CONCURRENTLY`.
El fix actual agrega el índice `referencedata.price_changes(programorderableid)`, necesario para
evitar que `/api/orderables` tarde decenas de segundos cuando hay muchos `program_orderables`.

## Configuración

```bash
cp env/dev.env.example env/dev.env     # ajustar REFDISTRO_DIR, creds de seed, etc.
```

`env/*.env` no se versiona (solo los `.example`). Los dumps (`backups/`, `baselines/`) tampoco.

Las imágenes personalizadas se seleccionan por ambiente y siempre deben usar una versión
inmutable, nunca `latest`:

```bash
REFERENCE_UI_IMAGE=ghcr.io/ghscpsm-cam/openlmis-gtm-ui:8.0.1-gtm.5
STOCKMANAGEMENT_IMAGE=ghcr.io/ghscpsm-cam/openlmis-gtm-stockmanagement:5.3.0-gtm.3
```

La UI incluye las traducciones GTM, la corrección de fechas de vencimiento y el filtro de
reportes por establecimiento principal. Los usuarios de bodega ven su categoría y los reportes
comunes; los administradores sin establecimiento asignado conservan la lista completa. La imagen
de Stock Management incluye el formato de Tarjeta de Almacén para nombres largos. Para promover
una nueva versión, primero se prueban ambas imágenes juntas y luego se actualizan estos valores.

## Estructura
```
platform                 # dispatcher (único entrypoint)
lib/common.sh            # helpers (env, compose del ref-distro, db, waits)
lib/commands.sh          # up/down/status/logs/seed/backup/restore/baseline/reset
overrides/               # overrides docker compose aplicados por platform
db-fixes/                # SQL idempotente aplicado por platform
env/{dev,test}.env.example
baselines/  backups/  logs/   # gitignored
```
