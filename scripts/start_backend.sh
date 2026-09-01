#!/usr/bin/env bash
set -euo pipefail

# Start a durable local Sloppa backend process.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="${SLOPPA_RUNTIME_DIR:-${project_dir}/.runtime}"
log_file="${SLOPPA_LOG_FILE:-${runtime_dir}/backend.log}"
pid_file="${SLOPPA_PID_FILE:-${runtime_dir}/backend.pid}"
bridge_bin="${SLOPPA_BIN:-${project_dir}/.venv/bin/sloppa}"
host="${SLOPPA_HOST:-127.0.0.1}"
port="${SLOPPA_PORT:-8080}"

if ! command -v curl >/dev/null 2>&1; then
  printf 'curl is required to start and verify the backend\n' >&2
  exit 1
fi
if [[ ! -x "$bridge_bin" ]]; then
  printf 'Sloppa backend executable not found at %s; create the project venv first\n' "$bridge_bin" >&2
  exit 1
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
  printf 'SLOPPA_PORT must be an integer between 1 and 65535\n' >&2
  exit 1
fi

health_host="$host"
case "$health_host" in
  0.0.0.0) health_host="127.0.0.1" ;;
  ::) health_host="::1" ;;
esac
if [[ "$health_host" == *:* ]]; then
  health_url="http://[${health_host}]:${port}/health"
else
  health_url="http://${health_host}:${port}/health"
fi

mkdir -p "$runtime_dir" "$(dirname "$log_file")" "$(dirname "$pid_file")"

if curl --silent --show-error --fail --max-time 2 "$health_url" >/dev/null; then
  printf 'backend already reachable at %s\n' "$health_url"
  exit 0
fi

if [[ -s "$pid_file" ]]; then
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    printf 'backend already running (pid %s); log: %s\n' "$pid" "$log_file"
    exit 0
  fi
  printf 'removing stale backend pid file: %s\n' "$pid_file" >&2
  rm -f "$pid_file"
fi

cd "$project_dir"
export SLOPPA_HOST="$host"
export SLOPPA_PORT="$port"
export SLOPPA_ALLOW_UNAUTH_REMOTE="${SLOPPA_ALLOW_UNAUTH_REMOTE:-0}"
nohup "$bridge_bin" --log-level "${SLOPPA_LOG_LEVEL:-INFO}" \
  >>"$log_file" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$pid_file"
ready=0
cleanup_pid() {
  if [[ "$ready" != 1 ]]; then
    rm -f "$pid_file"
  fi
}
trap cleanup_pid EXIT
printf 'backend started (pid %s) at http://%s:%s\nlog: %s\n' "$pid" "$host" "$port" "$log_file"

for _ in {1..15}; do
  if curl --silent --show-error --fail --max-time 2 "$health_url" >/dev/null; then
    ready=1
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'backend exited during startup; inspect %s\n' "$log_file" >&2
    exit 1
  fi
  sleep 1
done

printf 'backend did not become healthy within 15 seconds; inspect %s\n' "$log_file" >&2
exit 1
