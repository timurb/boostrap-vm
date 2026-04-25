#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STATE_DIR="${STATE_DIR:-/var/lib/vm-auto-poweroff}"
LAST_BUSY_FILE="${LAST_BUSY_FILE:-${STATE_DIR}/last_busy}"

IDLE_MINUTES="${IDLE_MINUTES:-30}"
CPU_BUSY_PERCENT="${CPU_BUSY_PERCENT:-20}"
DOCKER_BUSY_PERCENT="${DOCKER_BUSY_PERCENT:-5}"
CPU_SAMPLE_SECONDS="${CPU_SAMPLE_SECONDS:-2}"
DRY_RUN="${DRY_RUN:-0}"
SSH_PORTS="${SSH_PORTS:-22}"
BUSY_PROCESS_REGEX="${BUSY_PROCESS_REGEX:-apt(-get)?|aptitude|dpkg|unattended-upgrade|snap[[:space:]]|docker[[:space:]]+(build|compose)|docker-compose|buildkit|make|ninja|cmake|gcc|g[+][+]|clang|rustc|cargo|go[[:space:]]+(build|test|run)|npm|yarn|pnpm|bun|bundle([[:space:]]+install|[[:space:]]+exec)?|rails|rake|rspec|pytest|jest|vitest|playwright|cypress|mvn|gradle|pip3?|poetry}"
IGNORED_PROCESS_REGEX="${IGNORED_PROCESS_REGEX:-(^|[[:space:]/])codex[[:space:]]+app-server([[:space:]]|$)}"

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

die() {
  log "error: $*"
  exit 1
}

is_true() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_non_negative_int() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*) die "${name} must be a non-negative integer, got '${value}'" ;;
  esac
}

validate_config() {
  require_non_negative_int "IDLE_MINUTES" "$IDLE_MINUTES"
  require_non_negative_int "CPU_BUSY_PERCENT" "$CPU_BUSY_PERCENT"
  require_non_negative_int "DOCKER_BUSY_PERCENT" "$DOCKER_BUSY_PERCENT"
  require_non_negative_int "CPU_SAMPLE_SECONDS" "$CPU_SAMPLE_SECONDS"

  if (( IDLE_MINUTES == 0 )); then
    die "IDLE_MINUTES must be greater than 0"
  fi
}

ensure_state_dir() {
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    return 0
  fi

  if is_true "$DRY_RUN"; then
    log "dry-run: cannot create ${STATE_DIR}; continuing without state writes"
    return 0
  fi

  die "cannot create ${STATE_DIR}"
}

write_last_busy() {
  local timestamp="$1"

  ensure_state_dir

  if { printf '%s\n' "$timestamp" > "$LAST_BUSY_FILE"; } 2>/dev/null; then
    return 0
  fi

  if is_true "$DRY_RUN"; then
    log "dry-run: would record last busy timestamp ${timestamp} in ${LAST_BUSY_FILE}"
    return 0
  fi

  die "cannot write ${LAST_BUSY_FILE}"
}

read_last_busy() {
  local value=""

  if [[ -r "$LAST_BUSY_FILE" ]]; then
    value="$(tr -cd '0-9' < "$LAST_BUSY_FILE" | head -c 20)"
  fi

  printf '%s\n' "$value"
}

active_sessions_summary() {
  local output=""
  local who_lines=""
  local ssh_lines=""

  if command -v who >/dev/null 2>&1; then
    who_lines="$(who -u 2>/dev/null | awk '{print $1 " " $2 " " $3 " " $4}' || true)"
    if [[ -n "$who_lines" ]]; then
      output+="login sessions: ${who_lines//$'\n'/; }"$'\n'
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    local port
    for port in ${SSH_PORTS//,/ }; do
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      local port_lines=""
      port_lines="$(ss -Htn state established "( sport = :${port} )" 2>/dev/null \
        | awk -v port="$port" '{print "port " port " " $4 " <- " $5}' || true)"

      if [[ -n "$port_lines" ]]; then
        ssh_lines+="$port_lines"$'\n'
      fi
    done

    if [[ -n "$ssh_lines" ]]; then
      output+="ssh connections: ${ssh_lines//$'\n'/; }"$'\n'
    fi
  fi

  printf '%s' "$output"
}

read_cpu_times() {
  local label user nice system idle iowait irq softirq steal guest guest_nice

  read -r label user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

  local idle_all=$(( idle + iowait ))
  local non_idle=$(( user + nice + system + irq + softirq + steal ))
  local total=$(( idle_all + non_idle ))

  printf '%s %s\n' "$idle_all" "$total"
}

cpu_usage_percent() {
  local idle1 total1 idle2 total2 idle_delta total_delta busy_delta

  read -r idle1 total1 < <(read_cpu_times)
  sleep "$CPU_SAMPLE_SECONDS"
  read -r idle2 total2 < <(read_cpu_times)

  idle_delta=$(( idle2 - idle1 ))
  total_delta=$(( total2 - total1 ))

  if (( total_delta <= 0 )); then
    printf '0\n'
    return 0
  fi

  busy_delta=$(( total_delta - idle_delta ))
  printf '%s\n' "$(( (100 * busy_delta + total_delta / 2) / total_delta ))"
}

docker_cpu_percent() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi

  if ! docker info >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi

  timeout 10s docker stats --no-stream --format '{{.CPUPerc}}' 2>/dev/null \
    | awk '{ gsub(/%/, ""); total += $1 } END { printf "%.0f\n", total + 0 }'
}

busy_process_summary() {
  ps -eo pid=,ppid=,args= --no-headers 2>/dev/null \
    | awk -v self="$$" -v parent="$PPID" '
        $1 == self { next }
        $1 == parent { next }
        /vm[-_]auto[-_]poweroff/ { next }
        {
          $1 = ""
          $2 = ""
          sub(/^[[:space:]]+/, "")
          print
        }
      ' \
    | grep -Ev "$IGNORED_PROCESS_REGEX" \
    | grep -E "$BUSY_PROCESS_REGEX" \
    | head -n 5 || true
}

poweroff_vm() {
  if is_true "$DRY_RUN"; then
    log "dry-run: would run systemctl poweroff"
    return 0
  fi

  log "idle threshold reached; running systemctl poweroff"
  systemctl poweroff
}

main() {
  validate_config

  local now
  now="$(date +%s)"

  local -a reasons=()
  local sessions cpu docker_cpu processes

  sessions="$(active_sessions_summary)"
  if [[ -n "$sessions" ]]; then
    reasons+=("active sessions: ${sessions//$'\n'/ }")
  fi

  cpu="$(cpu_usage_percent)"
  if (( cpu >= CPU_BUSY_PERCENT )); then
    reasons+=("cpu ${cpu}% >= ${CPU_BUSY_PERCENT}%")
  fi

  docker_cpu="$(docker_cpu_percent)"
  if (( docker_cpu >= DOCKER_BUSY_PERCENT )); then
    reasons+=("docker cpu ${docker_cpu}% >= ${DOCKER_BUSY_PERCENT}%")
  fi

  processes="$(busy_process_summary)"
  if [[ -n "$processes" ]]; then
    reasons+=("busy processes: ${processes//$'\n'/; }")
  fi

  if (( ${#reasons[@]} > 0 )); then
    local reason_text
    printf -v reason_text '%s; ' "${reasons[@]}"
    reason_text="${reason_text%; }"
    write_last_busy "$now"
    log "busy: ${reason_text}"
    return 0
  fi

  local last_busy idle_seconds idle_minutes idle_limit_seconds
  last_busy="$(read_last_busy)"

  if [[ -z "$last_busy" ]]; then
    write_last_busy "$now"
    log "idle: no previous busy timestamp; starting ${IDLE_MINUTES} minute timer"
    return 0
  fi

  if (( last_busy > now )); then
    write_last_busy "$now"
    log "idle: last busy timestamp was in the future; reset timer"
    return 0
  fi

  idle_seconds=$(( now - last_busy ))
  idle_minutes=$(( idle_seconds / 60 ))
  idle_limit_seconds=$(( IDLE_MINUTES * 60 ))

  if (( idle_seconds < idle_limit_seconds )); then
    log "idle: ${idle_minutes} minute(s), waiting until ${IDLE_MINUTES} minute(s)"
    return 0
  fi

  log "idle: ${idle_minutes} minute(s), threshold is ${IDLE_MINUTES} minute(s)"
  poweroff_vm
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
