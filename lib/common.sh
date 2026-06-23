# lib/common.sh — helpers compartidos del comando platform.
set -euo pipefail

PLATFORM_DIR="${PLATFORM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VALID_ENVS=("dev" "test")

log()  { printf '%s %s\n' "$(date +'%H:%M:%S')" "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_env() {
  local e="${1:-}"
  local v
  for v in "${VALID_ENVS[@]}"; do [[ "$e" == "$v" ]] && return 0; done
  die "Ambiente inválido: '${e:-<vacío>}'. Usar: ${VALID_ENVS[*]} (prod no permitido)."
}

load_env() {
  local e="$1"
  local f="$PLATFORM_DIR/env/$e.env"
  [[ -f "$f" ]] || die "No existe $f. Copiá env/$e.env.example a env/$e.env y completá."
  set -a; # shellcheck disable=SC1090
  source "$f"; set +a
  ENVIRONMENT="$e"
  : "${REFDISTRO_DIR:?Falta REFDISTRO_DIR en $f}"
  : "${DB_CONTAINER:?Falta DB_CONTAINER en $f}"
  : "${DB_NAME:?Falta DB_NAME en $f}"
  : "${DB_USER:?Falta DB_USER en $f}"
  : "${OPENLMIS_URL:?Falta OPENLMIS_URL en $f}"
  [[ -d "$REFDISTRO_DIR" ]] || die "REFDISTRO_DIR no existe: $REFDISTRO_DIR"
  mkdir -p "$PLATFORM_DIR/logs" "$PLATFORM_DIR/backups" "$PLATFORM_DIR/baselines"
  LOGFILE="$PLATFORM_DIR/logs/platform_${e}_$(date +%Y%m%d-%H%M%S).log"
}

# docker compose del ref-distro existente (corre desde su dir para usar su propio .env)
rd_compose() { ( cd "$REFDISTRO_DIR" && docker compose "$@" ); }

# psql dentro del contenedor de BD
db_psql() { docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" "$@"; }

confirm() {
  # confirm <mensaje> — exige escribir CONFIRMO, salvo que se haya pasado --confirm/--yes.
  [[ "${ASSUME_YES:-}" == "1" ]] && return 0
  printf '%s\n' "$1"
  printf 'Escribí CONFIRMO para continuar: '
  local r; read -r r || true
  [[ "$r" == "CONFIRMO" ]] || die "Cancelado."
}

wait_for_openlmis() {
  local url="$OPENLMIS_URL/api/programs" max="${1:-120}" i=0 code
  log "Esperando que OpenLMIS responda ($url)..."
  while (( i < max )); do
    assert_critical_services_alive
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo 000)
    # 200 = ok, 401 = servicio arriba pero requiere auth (también "listo")
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      info "OpenLMIS responde (HTTP $code)."
      return 0
    fi
    sleep 10; i=$((i+1))
  done
  die "OpenLMIS no respondió tras ~$((max*10))s (último HTTP $code)."
}

assert_critical_services_alive() {
  local service cid state exit_code
  for service in auth referencedata nginx; do
    cid="$(rd_compose ps -q "$service" 2>/dev/null || true)"
    [[ -n "$cid" ]] || continue
    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo unknown)"
    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      err "Servicio crítico '$service' terminó durante el arranque (state=$state exit=$exit_code)."
      rd_compose logs --tail=80 "$service" >&2 || true
      exit 1
    fi
  done
}

db_wait_ready() {
  local i=0
  while ! docker exec -i "$DB_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then die "La BD ($DB_CONTAINER) no acepta conexiones."; fi
    sleep 2
  done
  return 0   # explícito: una función que termina en loop retorna el estado del cuerpo (gotcha set -e)
}

db_wait_database() {
  local i=0
  while ! docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then die "La base '$DB_NAME' no está disponible."; fi
    sleep 2
  done
  return 0
}
