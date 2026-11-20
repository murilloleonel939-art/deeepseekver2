FROM node:24-slim

# Dependencias necesarias para compilar módulos nativos.
# python3-venv permite crear el venv de graphify en tiempo de arranque sin
# depender de apt-get con red en cada despliegue; curl lo usa el instalador.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git ca-certificates curl python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /app
COPY . .

ENV NODE_OPTIONS="--max-old-space-size=3072"
ENV LEFTHOOK=0
ENV CI=true

RUN pnpm install --frozen-lockfile --network-concurrency 4

# El script de build necesita un repo git para leer el hash del commit
RUN git init \
    && git -c user.email="build@local" -c user.name="build" commit --allow-empty -m "build" \
    && pnpm run build

# Dominio por el que se accede (se puede sobrescribir desde Coolify > Environment Variables)
ENV TRUSTED_HOST="w5ygnd8hd0degm9matfoazhc.158.69.213.190.sslip.io"
ENV PUBLIC_URL="http://w5ygnd8hd0degm9matfoazhc.158.69.213.190.sslip.io/"

# El guard reinstala claude-mem y graphify solo si faltan en el volumen /root,
# y luego arranca la app. Edit entrypoint.sh, not this line.
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 3080

ENTRYPOINT ["/app/entrypoint.sh"]
