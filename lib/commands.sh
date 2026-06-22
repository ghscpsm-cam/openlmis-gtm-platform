# lib/commands.sh — implementación de los subcomandos de platform.
set -euo pipefail

cmd_help() {
cat <<'EOF'
platform — orquestador OpenLMIS (MSPAS). Un solo punto de entrada.

Uso: platform <comando> <dev|test> [args]

  up        <env>              Levanta OpenLMIS (ref-distro) y espera que responda
  down      <env>              Detiene servicios (sin borrar datos)
  status    <env>              Estado de servicios + OpenLMIS
  logs      <env> [servicio]   Logs del ref-distro
  seed      <env>              Siembra datos maestros (capa 2: openlmis-seeder)
  backup    <env>              pg_dump de la BD → backups/
  restore   <env> <archivo>    pg_restore de un dump (REEMPLAZA la BD)   [--confirm]
  baseline  <env>              Captura el estado ACTUAL como baseline esqueleto
  baseline-rebuild <env>       Reconstruye esqueleto PURO: BD vacía + re-migrar SIN demo  [--confirm]
  reset     <env>              Restaura baseline + re-siembra (limpio)   [--confirm]

Ambientes: dev | test  (prod no permitido). Comandos destructivos exigen --confirm.
EOF
}

cmd_up() {
  command -v docker >/dev/null || die "Docker no disponible"
  log "platform up $ENVIRONMENT" | tee -a "$LOGFILE"
  rd_compose up -d 2>&1 | tee -a "$LOGFILE"
  wait_for_openlmis | tee -a "$LOGFILE"
  cmd_status
}

cmd_down() {
  log "platform down $ENVIRONMENT (stop, sin borrar datos)" | tee -a "$LOGFILE"
  rd_compose stop 2>&1 | tee -a "$LOGFILE"
}

cmd_status() {
  printf '\n== Servicios (%s) ==\n' "$ENVIRONMENT"
  rd_compose ps || true
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "$OPENLMIS_URL/api/programs" || echo 000)
  printf '\nOpenLMIS %s/api/programs → HTTP %s (401=arriba con auth)\n' "$OPENLMIS_URL" "$code"
  printf 'UI: %s\n' "$OPENLMIS_URL"
}

cmd_logs() {
  rd_compose logs --tail="${TAIL:-200}" "$@"
}

cmd_seed() {
  : "${SEEDER_DIR:?Falta SEEDER_DIR en el .env}"
  : "${SEED_SET:?Falta SEED_SET en el .env}"
  [[ -d "$SEEDER_DIR" ]] || die "SEEDER_DIR no existe: $SEEDER_DIR"
  log "platform seed $ENVIRONMENT → set '$SEED_SET' (delegando a la capa 2)" | tee -a "$LOGFILE"
  local creds=()
  [[ -n "${SEED_USERNAME:-}" ]] && creds+=(-e "OPENLMIS_USERNAME=$SEED_USERNAME")
  [[ -n "${SEED_PASSWORD:-}" ]] && creds+=(-e "OPENLMIS_PASSWORD=$SEED_PASSWORD")
  ( cd "$SEEDER_DIR" && docker compose -f docker-compose.seed.yml run --rm "${creds[@]}" \
      seeder import "$ENVIRONMENT" "$SEED_SET" ) 2>&1 | tee -a "$LOGFILE"
}

cmd_backup() {
  local out="$PLATFORM_DIR/backups/${ENVIRONMENT}_$(date +%Y%m%d-%H%M%S).dump"
  log "platform backup $ENVIRONMENT → $out" | tee -a "$LOGFILE"
  docker exec -i "$DB_CONTAINER" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$out"
  info "Backup: $out ($(du -h "$out" | cut -f1))"
}

# restore_dump <archivo.dump> — patrón: stop → start db → drop/create → pg_restore → up.
restore_dump() {
  local dump="$1"
  [[ -f "$dump" ]] || die "No existe el dump: $dump"
  log "Restaurando BD de $ENVIRONMENT desde $dump" | tee -a "$LOGFILE"
  rd_compose stop 2>&1 | tee -a "$LOGFILE"
  rd_compose start db 2>&1 | tee -a "$LOGFILE"
  db_wait_ready
  db_psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null
  db_psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null
  db_psql -c "CREATE DATABASE $DB_NAME;" >/dev/null
  docker cp "$dump" "$DB_CONTAINER:/tmp/restore.dump"
  docker exec -i "$DB_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" /tmp/restore.dump 2>&1 | tee -a "$LOGFILE" || true
  docker exec -i "$DB_CONTAINER" rm -f /tmp/restore.dump || true
  rd_compose up -d 2>&1 | tee -a "$LOGFILE"
  wait_for_openlmis
}

cmd_restore() {
  local dump="${1:-}"
  [[ -n "$dump" ]] || die "Uso: platform restore <env> <archivo.dump>"
  [[ "$dump" = /* ]] || dump="$PLATFORM_DIR/$dump"
  confirm "Esto REEMPLAZA la BD de $ENVIRONMENT con: $dump"
  restore_dump "$dump"
  cmd_status
}

# Captura el estado ACTUAL de la BD como baseline esqueleto para reset.
cmd_baseline() {
  local out="${BASELINE_FILE:-baselines/${ENVIRONMENT}_baseline.dump}"
  [[ "$out" = /* ]] || out="$PLATFORM_DIR/$out"
  info "El baseline debe capturarse con OpenLMIS en estado 'esqueleto':"
  info "migrado, SIN datos de negocio ni transacciones (el seed los re-aplica en cada reset)."
  confirm "Se sobrescribirá el baseline '$out' con el estado ACTUAL de la BD de $ENVIRONMENT."
  log "Capturando baseline de $ENVIRONMENT → $out" | tee -a "$LOGFILE"
  docker exec -i "$DB_CONTAINER" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$out"
  info "Baseline: $out ($(du -h "$out" | cut -f1))"
}

# Reconstruye el baseline ESQUELETO PURO: BD vacía + re-migración SIN demo data.
# La demo data del ref-distro la carga un servicio aparte (overlay docker-compose.demo-data.yml),
# NO las migraciones. Un `up` normal (perfil production, sin overlay) sobre una BD vacía deja
# solo el bootstrap/required (incluido el usuario administrator), sin datos de negocio.
cmd_baseline_rebuild() {
  local out="${BASELINE_FILE:-baselines/${ENVIRONMENT}_baseline.dump}"
  [[ "$out" = /* ]] || out="$PLATFORM_DIR/$out"
  confirm "REBUILD baseline $ENVIRONMENT: down -v (ELIMINA volúmenes) y re-migra desde cero SIN demo data (varios minutos; $ENVIRONMENT queda vacío de datos de negocio). Se hace un backup antes."
  log "=== REBUILD baseline esqueleto $ENVIRONMENT (sin demo data) ===" | tee -a "$LOGFILE"
  cmd_backup
  # down -v borra los volúmenes: el postgres re-inicializa desde cero con sus extensiones
  # (postgis, etc.). Un simple DROP/CREATE DATABASE NO recrea las extensiones → la migración
  # de referencedata falla con: type "geometry" does not exist.
  log "Recreando el stack desde cero (down -v): elimina volúmenes y re-inicializa el postgres." | tee -a "$LOGFILE"
  rd_compose down -v 2>&1 | tee -a "$LOGFILE"
  # En una BD recién creada el init de la imagen NO crea postgis, y la migración de referencedata
  # necesita el tipo 'geometry'. El flujo manual con pg_restore no sufría esto porque el dump ya
  # trae postgis y el esquema migrado (los servicios no re-migran). Acá, como migramos desde cero,
  # hay que crear postgis ANTES: levantamos solo la BD, creamos la extensión, y luego el resto.
  log "Levantando solo la BD para preparar extensiones..." | tee -a "$LOGFILE"
  rd_compose up -d db 2>&1 | tee -a "$LOGFILE"
  db_wait_ready
  db_wait_database
  log "Creando extensión postgis en '$DB_NAME' (requerida por las migraciones)..." | tee -a "$LOGFILE"
  docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;" 2>&1 | tee -a "$LOGFILE"
  log "Levantando el resto de servicios (migración inicial, tarda varios minutos)..." | tee -a "$LOGFILE"
  rd_compose up -d 2>&1 | tee -a "$LOGFILE"
  wait_for_openlmis 180   # la migración inicial desde cero puede tardar varios minutos
  db_wait_ready
  docker exec -i "$DB_CONTAINER" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$out"
  info "Baseline esqueleto: $out ($(du -h "$out" | cut -f1))"
  info "Usuario bootstrap para seed: 'admin' (verificá que exista antes de usar 'reset')."
}

# reset = restaurar baseline esqueleto + re-sembrar desde los seed files (NO transacciones).
cmd_reset() {
  local baseline="${BASELINE_FILE:-baselines/${ENVIRONMENT}_baseline.dump}"
  [[ "$baseline" = /* ]] || baseline="$PLATFORM_DIR/$baseline"
  [[ -f "$baseline" ]] || die "No hay baseline ($baseline). Generalo con: platform baseline $ENVIRONMENT"
  confirm "RESET $ENVIRONMENT: restaura el baseline esqueleto y re-siembra. Se PIERDEN los datos actuales de $ENVIRONMENT."
  log "=== RESET $ENVIRONMENT ===" | tee -a "$LOGFILE"
  cmd_backup                      # respaldo de seguridad automático
  restore_dump "$baseline"        # estado limpio (esqueleto)
  cmd_seed                        # datos maestros desde los seed files
  cmd_status
  log "Reset completo: $ENVIRONMENT limpio + seed aplicado (sin transacciones)." | tee -a "$LOGFILE"
}
