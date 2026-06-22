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

## Uso

```bash
./platform up dev                 # levanta OpenLMIS y espera que responda
./platform status dev             # estado de servicios + OpenLMIS
./platform seed dev               # siembra datos maestros (capa 2)
./platform backup dev             # pg_dump → backups/
./platform restore dev backups/dev_20260622-1200.dump --confirm
./platform baseline dev           # captura el baseline limpio (1 vez, pg_dump)
./platform reset dev --confirm    # restaura baseline + re-siembra (~2.6 min)
./platform down dev               # detiene servicios (sin borrar datos)
```

`<env>` ∈ `{dev, test}` (prod no permitido). Los comandos destructivos exigen `--confirm`.

## Pruebas en limpio (`reset`) — baseline-por-dump (rápido y confiable)

Flujo recomendado para iterar en dev (**~2.6 min**, probado):

1. **Una sola vez** — llevá OpenLMIS al estado "limpio" que quieras y capturalo:
   `platform baseline dev` (es un `pg_dump`, segundos). Ese dump queda en `baselines/<env>_baseline.dump`.
2. **Cada vez que quieras limpio** — `platform reset dev --confirm`: restaura el baseline
   (segundos) + re-siembra desde los seed files. Hace un backup de seguridad automático antes.

El costo de ~2.6 min es casi todo el **reinicio de los servicios de OpenLMIS** (inherente; el
`pg_restore` es de segundos). El procedimiento manual equivalente tiene el mismo costo.

> ⚠️ **`baseline-rebuild` (migración fresca desde cero) NO se recomienda**: en este deployment es
> lento (~40 min) y frágil (la migración inicial de OpenLMIS choca con obstáculos del entorno —
> postgis y otros). Para "limpio rápido" usá un **baseline-por-dump** (`baseline` + `reset`),
> no la migración fresca. El dump de postgres es un *bind mount* (`./data`), por eso `down -v`
> no lo vacía.

> `backup`/`restore` son la herramienta general de snapshot/recuperación de la BD (pg_dump/pg_restore).

## Configuración

```bash
cp env/dev.env.example env/dev.env     # ajustar REFDISTRO_DIR, creds de seed, etc.
```

`env/*.env` no se versiona (solo los `.example`). Los dumps (`backups/`, `baselines/`) tampoco.

## Estructura
```
platform                 # dispatcher (único entrypoint)
lib/common.sh            # helpers (env, compose del ref-distro, db, waits)
lib/commands.sh          # up/down/status/logs/seed/backup/restore/baseline/reset
env/{dev,test}.env.example
baselines/  backups/  logs/   # gitignored
```
