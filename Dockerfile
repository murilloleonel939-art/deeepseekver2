FROM node:24-slim

# Instalar dependencias necesarias para compilar módulos nativos
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /app
COPY . .

# Limitar memoria y concurrencia para evitar que el VPS se quede sin RAM
ENV NODE_OPTIONS="--max-old-space-size=3072"
RUN pnpm install --frozen-lockfile --network-concurrency 4

# El script de build necesita un repo git para leer el hash del commit
# (Coolify no incluye la carpeta .git en el contexto de build)
ARG SOURCE_COMMIT=unknown
RUN git init \
    && git -c user.email="build@local" -c user.name="build" commit --allow-empty -m "build ${SOURCE_COMMIT}" \
    && pnpm run build

EXPOSE 3080

CMD ["pnpm", "dsh", "web", "--no-open", "--host", "0.0.0.0", "--port", "3080"]
