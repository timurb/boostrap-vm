#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="vm-auto-poweroff.service"
TIMER_NAME="vm-auto-poweroff.timer"
CONFIG_FILE="/etc/default/vm-auto-poweroff"
INSTALL_BIN="/usr/local/sbin/vm-auto-poweroff"
SYSTEMD_DIR="/etc/systemd/system"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run with sudo: sudo ./install_vm_auto_poweroff.sh"
  fi
}

require_file() {
  local path="$1"

  [[ -f "$path" ]] || die "missing required file: ${path}"
}

require_non_negative_int() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*) die "${name} must be a non-negative integer, got '${value}'" ;;
  esac
}

write_default_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log "Keeping existing ${CONFIG_FILE}"
    return 0
  fi

  log "Creating ${CONFIG_FILE}"
  cat > "$CONFIG_FILE" <<'EOF'
# Minutes without detected activity before local VM poweroff.
IDLE_MINUTES=30

# Personal SSH login sessions with TTY idle time below this value block poweroff.
SSH_SESSION_IDLE_MINUTES=30

# Installer uses this value to generate the systemd timer interval.
# Rerun sudo ./install_vm_auto_poweroff.sh after changing it.
CHECK_INTERVAL_SECONDS=300

# Set to 1 to log the decision without calling systemctl poweroff.
DRY_RUN=0

# VM-wide CPU usage threshold that blocks poweroff.
CPU_BUSY_PERCENT=20

# Sum of Docker container CPU percentages that blocks poweroff.
DOCKER_BUSY_PERCENT=5

# Regex for long-lived client bridge/LSP processes that should not block
# poweroff. Leave unset to use script defaults.
# IGNORED_PROCESS_REGEX='(^|[[:space:]/])codex[[:space:]]+app-server([[:space:]]|$)|ruby[-_]lsp|ruby_lsp_rails|ruby-lsp-rails'
EOF
}

load_config() {
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"

  CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-300}"
  require_non_negative_int "CHECK_INTERVAL_SECONDS" "$CHECK_INTERVAL_SECONDS"

  if (( CHECK_INTERVAL_SECONDS == 0 )); then
    die "CHECK_INTERVAL_SECONDS must be greater than 0"
  fi
}

write_timer() {
  log "Installing ${SYSTEMD_DIR}/${TIMER_NAME}"
  cat > "${SYSTEMD_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Run VM auto poweroff check every ${CHECK_INTERVAL_SECONDS} seconds

[Timer]
OnBootSec=${CHECK_INTERVAL_SECONDS}s
OnUnitActiveSec=${CHECK_INTERVAL_SECONDS}s
AccuracySec=30s
Unit=${SERVICE_NAME}
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

main() {
  require_root

  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

  require_file "${script_dir}/vm_auto_poweroff.sh"
  require_file "${script_dir}/${SERVICE_NAME}"

  log "Installing ${INSTALL_BIN}"
  install -D -m 0755 "${script_dir}/vm_auto_poweroff.sh" "$INSTALL_BIN"

  log "Installing ${SYSTEMD_DIR}/${SERVICE_NAME}"
  install -D -m 0644 "${script_dir}/${SERVICE_NAME}" "${SYSTEMD_DIR}/${SERVICE_NAME}"

  install -d -m 0755 "$(dirname "$CONFIG_FILE")"
  write_default_config
  load_config
  write_timer

  log "Reloading systemd"
  systemctl daemon-reload

  log "Enabling ${TIMER_NAME}"
  systemctl enable --now "$TIMER_NAME"

  log "Installed. Check logs with: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
}

main "$@"
