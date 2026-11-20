FROM node:24-slim

# Dependencias necesarias para compilar módulos nativos + claude-mem
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# claude-mem se instala en /root/.npm-global → VOLUMEN PERSISTENTE
ENV NPM_CONFIG_PREFIX=/root/.npm-global
ENV PATH=/root/.npm-global/bin:/root/.local/bin:$PATH

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

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3080

ENTRYPOINT ["/entrypoint.sh"]
