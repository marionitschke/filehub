#!/bin/bash
# Local test server (Docker/OrbStack) for scripts/check.sh --server and scripts/e2e.sh.
#
#   scripts/testserver.sh          → build and start (ports on 127.0.0.1 only)
#   scripts/testserver.sh stop     → remove the container
#   scripts/testserver.sh delay 40 → 40 ms latency per direction like the internet (0 = off)
#
# SFTP 2222, FTPS/vsftpd 2121 (LIST), FTPS/Pure-FTPd 2122 (MLSD), FTP without TLS 2123,
# FTPS/ProFTPD 2124 (like All-inkl).
# User "filehub", password "filehub-test-pw": test values only. The test CA and a test key
# go to build/test/; only the check runs trust them.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=filehub-testserver
DOCKER=$(command -v docker || echo /usr/local/bin/docker)

if [[ "${1:-}" == "delay" ]]; then
  "$DOCKER" exec "$NAME" tc qdisc del dev eth0 root 2>/dev/null || true
  if [[ "${2:-0}" != "0" ]]; then
    "$DOCKER" exec "$NAME" tc qdisc add dev eth0 root netem delay "${2}ms"
  fi
  echo "Netzlaufzeit: ${2:-0} ms"
  exit 0
fi

if [[ "${1:-}" == "stop" ]]; then
  "$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
  echo "Prüf-Server entfernt."
  exit 0
fi

mkdir -p build/test
"$DOCKER" build -q -t filehub-testserver Tests/server >/dev/null
"$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
# Pure-FTPd exits silently without these capabilities (exit 252). NET_ADMIN for "delay" (tc netem).
"$DOCKER" run -d --name "$NAME" \
  --cap-add SYS_ADMIN --cap-add SYS_NICE --cap-add DAC_READ_SEARCH --cap-add NET_ADMIN \
  -p 127.0.0.1:2222:2222 -p 127.0.0.1:2121:2121 -p 127.0.0.1:2122:2122 -p 127.0.0.1:2123:2123 -p 127.0.0.1:2124:2124 \
  -p 127.0.0.1:21100-21115:21100-21115 -p 127.0.0.1:30000-30019:30000-30019 \
  filehub-testserver >/dev/null

"$DOCKER" cp "$NAME:/etc/ssl/filehub/ca.pem" build/test/ca.pem
[[ -f build/test/id_test ]] || ssh-keygen -q -t ed25519 -N "" -C filehub-test -f build/test/id_test
"$DOCKER" cp build/test/id_test.pub "$NAME:/home/filehub/.ssh/authorized_keys"
"$DOCKER" exec "$NAME" sh -c 'chown filehub:filehub /home/filehub/.ssh/authorized_keys && chmod 600 /home/filehub/.ssh/authorized_keys'

for _ in $(seq 1 50); do
  nc -z 127.0.0.1 2222 2>/dev/null && nc -z 127.0.0.1 2122 2>/dev/null && nc -z 127.0.0.1 2124 2>/dev/null && break
  sleep 0.2
done
echo "Prüf-Server läuft ($NAME)."
