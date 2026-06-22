# Plan — `openlmis-gua-platform`

Paraguas institucional para el MSPAS: **un único punto de entrada `./platform`** que orquesta
tres capas separadas sobre OpenLMIS. El objetivo es que el equipo MSPAS use siempre el mismo
comando sin recordar qué YAML usar, qué variables exportar, qué red Docker, cómo esperar a que
OpenLMIS responda, etc.

```
platform
   ├── levanta OpenLMIS con Docker Compose      (Capa 1 — Plataforma)
   ├── crea o recupera un TEST limpio           (Capa 1 — backup/restore/reset)
   ├── aplica configuración mínima de plataforma
   ├── llama al wrapper del seeder oficial       (Capa 2 — Seed de maestros)
   └── llama al importer de transacciones        (Capa 3 — Importación)
```

Secuencia ideal (cada paso es **deliberado**, nunca automático por defecto):
```
platform up test                          → OpenLMIS y servicios activos
platform seed test                        → datos maestros (facilities, zonas, productos, usuarios…)
platform import-transactions test x.csv   → movimientos/transacciones aprobadas
```

> Principio rector: **separar responsabilidades**. Levantar plataforma, sembrar maestros y cargar
> transacciones son operaciones distintas. No un script gigante que "levanta, borra, siembra y carga"
> siempre. Separar = más seguro, auditable y transferible.

---

## 0. Las tres capas y su frontera

| Capa | Repo / motor | Qué hace | Qué **no** hace |
|---|---|---|---|
| **1. Plataforma** | `openlmis-gua-platform` (este) + imágenes ref-distro | Levanta/baja OpenLMIS, backup/restore/reset, status/logs | No siembra ni carga transacciones automáticamente |
| **2. Seed maestros** | `openlmis-seeder` (wrapper Node + jar oficial, ver su PLAN.md) | Carga datos de **referencia** (niveles/zonas geográficas, facility types, facilities, programas, productos, catálogos, nodos supervisores, supply lines, períodos, roles, usuarios) vía CSV+mappings | No carga movimientos cotidianos de inventario |
| **3. Transacciones** | `openlmis-importer` (ya existe) | Carga **movimientos** (stock events, lotes) | No crea datos maestros |

El Reference Data Service de OpenLMIS contiene las listas maestras; se cargan masivamente con el
Seed Tool o sus APIs. Por eso el seed va **después** de que la plataforma esté levantada (el seeder
inserta vía API, necesita la instancia viva).

---

## 1. Decisión de repos (recomendada)

**Tres repos, no un monorepo gigante.** `openlmis-gua-platform` es el paraguas: contiene
orquestación + datos institucionales + compose + el comando `platform`. Los **motores** se consumen
como **imágenes Docker con tag/commit fijado**, no como código embebido:

| Repo | Produce | Se consume en platform como |
|---|---|---|
| `openlmis-importer` (existe) | imagen `openlmis-importer-local` | servicio en `docker-compose.importer.yml` |
| `openlmis-seeder` (Capa 2) | imagen `openlmis-seed` (jar pin `14730436…`) | servicio en `docker-compose.seed.yml` |
| ref-distro oficial | imágenes `openlmis/*:15.4.0` etc. | `docker-compose.yml` + overrides dev/test |

- **Mappings** (técnicos, atados al esquema del referencedata) viven **con el seeder**, baked en su
  imagen. El MSPAS **no** los toca.
- **Datos institucionales** (CSV de facilities, usuarios, etc.) viven en este repo, en `seed/`, y se
  montan en el contenedor del seeder en runtime. Así el MSPAS no entra a Gradle ni al repo oficial.

> Esto resuelve la consistencia con la decisión previa del seeder: el institucional usa `platform seed
> test`; por debajo eso invoca el **CLI Node del seeder** (`seed import …`), no un `run_seed.sh`.

---

## 2. Comando único `./platform` → mapa de subcomandos

Internamente puede haber scripts separados, pero el usuario institucional usa **un solo entrypoint**.

| Comando | Capa | Acción |
|---|---|---|
| `platform up <env>` | 1 | Levanta OpenLMIS (sin seed automático). |
| `platform down <env>` | 1 | Baja servicios (sin borrar datos). |
| `platform status <env>` | 1 | Estado de servicios + URLs. |
| `platform logs <env>` | 1 | Logs agregados / ruta de logs. |
| `platform backup <env>` | 1 | Backup (volúmenes/DB) a `backups/`. |
| `platform restore <env> <archivo>` | 1 | Restaura desde un backup específico. |
| `platform reset <env> --confirm [--from-baseline]` | 1 | Reconstruye TEST: desde cero+seed base (def.) o restaura baseline (ver §4). |
| `platform seed <env>` | 2 | Delega al seeder wrapper (maestros). |
| `platform import-transactions <env> <csv>` | 3 | Delega al importer (movimientos). |

`<env>` ∈ `{dev, test}`. **Nunca** default a prod. Comandos destructivos exigen `--confirm`.

---

## 3. `platform up <env>` — qué hace (orden exacto)
1. Cargar variables del ambiente (`env/<env>.env`).
2. Validar que Docker y Docker Compose estén disponibles.
3. Validar que existan los `.env` requeridos (y secretos montados).
4. Levantar OpenLMIS con los YAML correspondientes (`docker-compose.yml` + override `<env>`).
5. Esperar health checks / respuestas HTTP mínimas (poll con timeout).
6. Validar que los servicios principales estén disponibles.
7. Mostrar URLs, estado y ruta de logs.
8. **No** aplicar seed automáticamente (salvo flag explícito).

---

## 4. `platform reset test` — el procedimiento más delicado
1. Solicita confirmación explícita (`--confirm`).
2. Backup automático previo (opcional, recomendado).
3. Detiene servicios.
4. Elimina **solo** los volúmenes/datos definidos para TEST.
5. Levanta plataforma limpia.
6. Espera que OpenLMIS responda.
7. Ejecuta **seed base** (maestros), **no** transacciones.
8. Valida servicios.
9. Entrega URL, logs y resumen.

Resultado esperado: **TEST reconstruido + OpenLMIS disponible + seed base aplicado + logs guardados +
estado validado**. Reset termina con TEST limpio y datos maestros; las transacciones se cargan
después, deliberadamente.

> **Decisión tomada:** `reset` soporta **ambos modos**. Por defecto = **desde cero + seed base**
> (`down -v` → `up` → `seed base`), reproducible y determinista. Con `--from-baseline` restaura un
> *baseline backup* en lugar de reconstruir. `restore <env> <archivo>` sigue existiendo para volver a
> un backup puntual cualquiera.

---

## 5. Capa 2 — `platform seed <env>` (resumen; detalle en el seeder)
Delega al wrapper `openlmis-seeder` (CLI Node estilo importer, motor = jar oficial pin
`14730436…`, referencedata 15.4.0). Carga **solo datos de referencia**. Registra commit, archivos
usados y resultado. Valida la carga vía API. **No** carga movimientos.
→ Ver `../openlmis-seeder/PLAN.md`.

## 6. Capa 3 — `platform import-transactions <env> <csv>`
Delega al `openlmis-importer` existente. Debe: validar formato y columnas, validación previa sin
modificar datos cuando sea posible, generar log, ejecutar la carga, reporte de errores, evitar
duplicados, y registrar lote/fecha/usuario/resultado.

> **Decisión tomada:** Capa 3 **diferida** en el primer build. El adapter `import-transactions.sh`
> queda como *stub* hasta cerrar el formato/alcance de transacciones; luego se integra el
> `openlmis-importer` existente (ya resuelve idempotencia, etc.). Capas 1 y 2 van primero.

---

## 7. Estructura del repo `openlmis-gua-platform`

```
openlmis-gua-platform/
├── compose/
│   ├── docker-compose.yml          # base ref-distro (pin 15.4.0)
│   ├── docker-compose.dev.yml
│   ├── docker-compose.test.yml
│   ├── docker-compose.seed.yml     # servicio openlmis-seed (Capa 2)
│   └── docker-compose.importer.yml # servicio importer (Capa 3)
├── env/
│   ├── dev.env.example
│   ├── test.env.example
│   └── secrets/.gitkeep            # secretos fuera de Git
├── scripts/
│   ├── platform                    # ÚNICO entrypoint (dispatcher)
│   ├── platform-up.sh  platform-down.sh  platform-status.sh
│   ├── backup.sh  restore.sh  reset-test.sh
│   ├── run-seed.sh                 # adapter → CLI del seeder
│   └── import-transactions.sh      # adapter → importer
├── seed/
│   ├── common/                     # línea base institucional estable
│   ├── dev/                        # usuarios/datos de desarrollo
│   └── test/                       # datos cercanos a validación oficial
├── imports/
│   ├── templates/                  # plantillas de transacciones
│   └── staging/                    # archivos a cargar
├── backups/.gitkeep
├── logs/.gitkeep
└── docs/
    ├── platform-guide.md  seed-guide.md  import-guide.md  recovery-guide.md
```

### Línea base de datos (qué es "datos básicos")
- `seed/common/`: estructura institucional estable (GeographicLevels, GeographicZones, FacilityTypes,
  Facilities, Programs, CommodityTypes, CatalogItems, Roles, Users, SupplyLines…).
- `seed/dev/`: pruebas y usuarios de desarrollo.
- `seed/test/`: datos cercanos a la validación oficial (Facilities, Users, ProcessingPeriods…).
- **Regla:** transacciones **nunca** se mezclan con seed.

---

## 8. Versiones / pins (verificado en prod)

| Componente | Versión / pin |
|---|---|
| referencedata | **15.4.0** (stockmanagement 5.3.0, auth 4.4.0, requisition 8.5.0, fulfillment 9.3.0) |
| postgres | 14-debezium |
| seeder oficial | commit `14730436363895c638071a16aed8fa53e7097519` (sep-2025) |
| importer | imagen `openlmis-importer-local` (repo existente) |

Pendiente: confirmar que **dev** corre la misma 15.4.0 (`ssh openlmisdev`,
`grep OL_REFERENCEDATA_VERSION ~/openlmis-ref-distro/.env`).

---

## 9. Plan de implementación (6 etapas)

| Etapa | Entregable |
|---|---|
| **1. Definir plataforma** | Confirmar versión OpenLMIS, fijar imágenes/commits, crear repo `openlmis-gua-platform`, YAML base+dev+test, variables por ambiente, proxy/dominios/redes/certs, instancia reproducible. |
| **2. Wrapper Platform** | Implementar `./platform` con `up/down/status/logs`; validaciones y mensajes claros; logs con fecha/ambiente/resultado; protección de comandos destructivos. |
| **3. Backups y reset** | `backup`, `restore`, `reset test`; probar una restauración real; probar que TEST se reconstruye desde cero. |
| **4. Seeder wrapper** | Contenedor `openlmis-seed`; carpetas CSV+mappings; `platform seed dev/test`; registrar commit/archivos/resultado; validar carga por API e interfaz. (= `openlmis-seeder`) |
| **5. Importer** | Confirmar formato de transacciones; plantilla; validación previa; importador separado; pruebas con archivos controlados; evitar duplicados/reprocesos. |
| **6. Documentación y transferencia** | Manual de comandos, manual de recuperación, inventario de variables, diagrama de componentes; ejercicio práctico: reset TEST → seed → importación → validación. |

---

## 10. Decisiones pendientes antes de implementar

**Técnicas (las resuelvo / propongo yo):**
1. ✅ Versión base: referencedata 15.4.0 (confirmar dev).
2. Qué servicios del ref-distro usa realmente Guatemala (¿buq, cce, dhis2-integration, hapifhir?
   → recortar el compose a lo que se use).
3. Qué datos pertenecen al seed base (definir `seed/common`).

**Del cliente / MSPAS (gobernanza — van documentadas, no las decido yo):**
4. Qué datos se pueden cambiar libremente en DEV.
5. Qué datos requieren aprobación antes de entrar a TEST.
6. Formato exacto de transacciones (bloquea la Capa 3).
7. Significado de "reset TEST": desde cero vs desde baseline (ver §4 — propongo desde cero).
8. Quién autoriza una carga con `updateAllowed`.
9. Dónde se guardan los backups (local, S3, etc.).
10. Qué usuario puede ejecutar comandos destructivos.
11. Qué secretos se manejan fuera de Git.
12. Qué validación final debe pasar para declarar TEST "listo".

---

## 11. Relación con el otro plan
- **Capa 2** está detallada en `openlmis-seeder/PLAN.md` (CLI `seed` estilo importer, motor jar
  pin, validación estructural, processed/rejected, reporte legible).
- **Capa 3** reutiliza el `openlmis-importer` existente.
- Este documento define **Capa 1** + la unificación bajo `./platform`.
