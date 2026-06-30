#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.winver.dashboard"
DOMAIN="gui/$(id -u)"
APP_ROOT="${HOME}/Library/Application Support/winver-dashboard"
RUNTIME_ROOT="${APP_ROOT}/runtime"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/winver"
PORT="${WINVER_DASHBOARD_PORT:-8787}"
ACTION="${1:-install}"

sync_runtime() {
  rm -rf "${RUNTIME_ROOT}"
  mkdir -p "${RUNTIME_ROOT}"
  /usr/bin/ditto "${SOURCE_ROOT}/bin" "${RUNTIME_ROOT}/bin"
  /usr/bin/ditto "${SOURCE_ROOT}/lib" "${RUNTIME_ROOT}/lib"
  /usr/bin/ditto "${SOURCE_ROOT}/dashboard" "${RUNTIME_ROOT}/dashboard"
  if [[ -f "${SOURCE_ROOT}/.env" ]]; then /usr/bin/ditto "${SOURCE_ROOT}/.env" "${RUNTIME_ROOT}/.env"; fi
  if [[ -f "${SOURCE_ROOT}/winver.local.json" ]]; then /usr/bin/ditto "${SOURCE_ROOT}/winver.local.json" "${RUNTIME_ROOT}/winver.local.json"; fi
}

write_plist() {
  mkdir -p "$(dirname "${PLIST}")" "${LOG_DIR}"
  cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNTIME_ROOT}/bin/winver</string>
    <string>dashboard</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${RUNTIME_ROOT}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/dashboard.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/dashboard.err.log</string>
</dict>
</plist>
PLIST
}

stop_agent() {
  launchctl bootout "${DOMAIN}" "${PLIST}" 2>/dev/null || true
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
}

case "${ACTION}" in
  install|restart)
    sync_runtime
    write_plist
    stop_agent
    launchctl bootstrap "${DOMAIN}" "${PLIST}"
    launchctl kickstart -k "${DOMAIN}/${LABEL}"
    echo "winver dashboard agent running at http://127.0.0.1:${PORT}"
    ;;
  uninstall|remove|stop)
    stop_agent
    rm -f "${PLIST}"
    echo "winver dashboard agent removed"
    ;;
  status)
    launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null || {
      echo "winver dashboard agent is not loaded"
      exit 1
    }
    ;;
  *)
    echo "Usage: $0 [install|restart|status|uninstall]" >&2
    exit 2
    ;;
esac
