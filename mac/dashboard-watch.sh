#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${HOME}/Library/Application Support/winver-dashboard/runtime"
ROOT="${WINVER_DASHBOARD_RUNTIME_ROOT:-${SOURCE_ROOT}}"
PORT="${WINVER_DASHBOARD_PORT:-8787}"
LOG_DIR="${HOME}/Library/Logs/winver"
PID_FILE="${LOG_DIR}/dashboard-watch.pid"
WATCH_LOG="${LOG_DIR}/dashboard-watch.log"
OUT_LOG="${LOG_DIR}/dashboard.out.log"
ERR_LOG="${LOG_DIR}/dashboard.err.log"
ACTION="${1:-start}"

mkdir -p "${LOG_DIR}"

sync_runtime() {
  rm -rf "${RUNTIME_ROOT}"
  mkdir -p "${RUNTIME_ROOT}"
  /usr/bin/ditto "${SOURCE_ROOT}/bin" "${RUNTIME_ROOT}/bin"
  /usr/bin/ditto "${SOURCE_ROOT}/lib" "${RUNTIME_ROOT}/lib"
  /usr/bin/ditto "${SOURCE_ROOT}/dashboard" "${RUNTIME_ROOT}/dashboard"
  /usr/bin/ditto "${SOURCE_ROOT}/mac" "${RUNTIME_ROOT}/mac"
  if [[ -f "${SOURCE_ROOT}/.env" ]]; then /usr/bin/ditto "${SOURCE_ROOT}/.env" "${RUNTIME_ROOT}/.env"; fi
  if [[ -f "${SOURCE_ROOT}/winver.local.json" ]]; then /usr/bin/ditto "${SOURCE_ROOT}/winver.local.json" "${RUNTIME_ROOT}/winver.local.json"; fi
}

is_running() {
  [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

run_watch() {
  echo "$$" > "${PID_FILE}"
  child=""
  cleanup() {
    if [[ -n "${child}" ]] && kill -0 "${child}" 2>/dev/null; then
      kill "${child}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
  }
  trap cleanup EXIT INT TERM

  while true; do
    if /usr/sbin/lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
      sleep 10
      continue
    fi

    {
      echo ""
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] starting winver dashboard on 127.0.0.1:${PORT}"
    } >> "${WATCH_LOG}"

    "${ROOT}/bin/winver" dashboard --port "${PORT}" >> "${OUT_LOG}" 2>> "${ERR_LOG}" &
    child="$!"
    wait "${child}" || true
    child=""
    sleep 3
  done
}

case "${ACTION}" in
  start)
    if is_running; then
      echo "winver dashboard watcher already running (pid $(cat "${PID_FILE}"))"
      exit 0
    fi
    sync_runtime
    WINVER_DASHBOARD_RUNTIME_ROOT="${RUNTIME_ROOT}" nohup "${RUNTIME_ROOT}/mac/dashboard-watch.sh" run >> "${WATCH_LOG}" 2>&1 &
    echo $! > "${PID_FILE}"
    echo "winver dashboard watcher started at http://127.0.0.1:${PORT}"
    ;;
  run)
    run_watch
    ;;
  stop)
    if is_running; then
      kill "$(cat "${PID_FILE}")"
      rm -f "${PID_FILE}"
      echo "winver dashboard watcher stopped"
    else
      echo "winver dashboard watcher is not running"
    fi
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    if is_running; then
      echo "winver dashboard watcher running (pid $(cat "${PID_FILE}"))"
    else
      echo "winver dashboard watcher is not running"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 [start|stop|restart|status]" >&2
    exit 2
    ;;
esac
