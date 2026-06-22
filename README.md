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
./platform baseline dev           # captura el baseline esqueleto (1 vez)
./platform reset dev --confirm    # restaura baseline + re-siembra (limpio)
./platform down dev               # detiene servicios (sin borrar datos)
```

`<env>` ∈ `{dev, test}` (prod no permitido). Los comandos destructivos exigen `--confirm`.

## Pruebas en limpio (`reset`) — desde seed, no desde un backup de datos

`reset` está diseñado para iterar pruebas rápido **sin** restaurar un dump de datos viejos:

1. `platform baseline dev` — una sola vez, captura el **esqueleto**: OpenLMIS migrado, SIN datos
   de negocio ni transacciones.
2. `platform reset dev --confirm` — restaura ese baseline (segundos) y **re-siembra desde los
   seed files** (fuente de verdad versionada). Hace un backup de seguridad automático antes.

Resultado: ambiente limpio + datos maestros del seed, sin cruft de pruebas anteriores y **sin**
depender de un dump de datos. Las transacciones nunca se cargan en reset; se cargan aparte y a
propósito.

> Backup/restore (`backup`/`restore`) son distintos: pg_dump/pg_restore de la BD real, para
> snapshotear y recuperar estado a propósito. Esos sí mueven datos.

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
