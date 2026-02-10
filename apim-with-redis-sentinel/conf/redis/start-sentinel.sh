#!/bin/sh
set -eu

MASTER_HOST="${MASTER_HOST:-redis-master}"
SRC_CONF="${SRC_CONF:-/usr/local/etc/redis/sentinel.conf}"
DST_CONF="${DST_CONF:-/tmp/sentinel.conf}"

echo "[start-sentinel] Waiting for DNS: ${MASTER_HOST}"
until getent hosts "${MASTER_HOST}" >/dev/null 2>&1; do
  echo "[start-sentinel] DNS not ready for ${MASTER_HOST}, retrying..."
  sleep 1
done

MASTER_IP="$(getent hosts "${MASTER_HOST}" | awk 'NR==1{print $1}')"
echo "[start-sentinel] MASTER_IP=${MASTER_IP}"

# Template'i writable konuma kopyala ve IP'yi inject et
sed "s/__MASTER_IP__/${MASTER_IP}/g" "${SRC_CONF}" > "${DST_CONF}"
chmod 600 "${DST_CONF}"

echo "[start-sentinel] Using writable conf: ${DST_CONF}"
echo "[start-sentinel] monitor line: $(grep -E "^sentinel monitor" "${DST_CONF}" || true)"

# Sentinel config dosyasını runtime'da rewrite edeceği için /tmp iyi.
exec redis-sentinel "${DST_CONF}"
