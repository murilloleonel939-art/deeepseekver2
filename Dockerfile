FROM node:24-slim

# Dependencias necesarias para compilar módulos nativos
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git ca-certificates \
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

EXPOSE 3080

# La app rechaza 0.0.0.0, así que se enlaza a la IPv4 concreta del contenedor
CMD IP=$(hostname -i | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1); exec pnpm dsh web --no-open --host "$IP" --port 3080 --public-url "$PUBLIC_URL" --trusted-host "$TRUSTED_HOST"
