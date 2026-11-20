#!/bin/bash
set -euo pipefail

# Instala claude-mem SOLO si no está ya en el volumen persistente.
# Primera vez: ~10-15s. Siguientes arranques: ~0s.
if [ ! -x /root/.npm-global/bin/claude-mem ]; then
  echo "[entrypoint] claude-mem no encontrado, instalando en volumen persistente..."
  npm install -g claude-mem@16.0.2
else
  echo "[entrypoint] claude-mem ya instalado ($(claude-mem version 2>/dev/null || echo ok))"
fi

mkdir -p /root/.local/bin

# La app rechaza 0.0.0.0, así que se enlaza a la IPv4 concreta del contenedor
IP=$(hostname -i | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
exec pnpm dsh web --no-open --host "$IP" --port 3080 \
  --public-url "$PUBLIC_URL" --trusted-host "$TRUSTED_HOST"
