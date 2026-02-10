#!/bin/sh
set -eu

SENTINEL_HOST="${SENTINEL_HOST:-redis-sentinel-1}"
SENTINEL_PORT="${SENTINEL_PORT:-26379}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"

HAPROXY_CFG="${HAPROXY_CFG:-/usr/local/etc/haproxy/haproxy.cfg}"
HAPROXY_PID="${HAPROXY_PID:-/var/run/haproxy.pid}"

log() { echo "$(date -Iseconds) [watcher] $*"; }

current=""

log "Starting. Sentinel=${SENTINEL_HOST}:${SENTINEL_PORT}, masterName=${MASTER_NAME}"

while true; do
  out="$(redis-cli -h "${SENTINEL_HOST}" -p "${SENTINEL_PORT}" SENTINEL get-master-addr-by-name "${MASTER_NAME}" || true)"
  host="$(printf "%s\n" "$out" | sed -n '1p' | tr -d '\r\n"')"
  port="$(printf "%s\n" "$out" | sed -n '2p' | tr -d '\r\n"')"

  if [ -z "${host}" ] || [ -z "${port}" ] || [ "${host}" = "(nil)" ]; then
    log "WARN: Could not resolve master yet. out='${out}'"
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  next="${host}:${port}"
  if [ "${next}" != "${current}" ]; then
    log "Master changed: '${current}' -> '${next}'"

    tmp="/tmp/haproxy.cfg.new"
    sed -E \
      "s#(^[[:space:]]*server[[:space:]]+redis-master[[:space:]]+)[^[:space:]]+#\1${host}:${port}#g" \
      "${HAPROXY_CFG}" > "${tmp}"
    cat "${tmp}" > "${HAPROXY_CFG}"
    rm -f "${tmp}"

    # Reload haproxy (pid varsa)
    if [ -f "${HAPROXY_PID}" ]; then
      pid="$(cat "${HAPROXY_PID}" 2>/dev/null || true)"
      if [ -n "${pid}" ]; then
        log "Reloading HAProxy via HUP pid=${pid}"
        kill -HUP "${pid}" 2>/dev/null || true
      else
        log "WARN: PID file present but empty"
      fi
    else
      log "WARN: HAProxy pidfile not found at ${HAPROXY_PID}"
    fi

    current="${next}"
  fi

  sleep "${CHECK_INTERVAL}"
done
