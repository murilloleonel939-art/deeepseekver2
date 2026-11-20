FROM node:24-slim

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

RUN git init \
    && git -c user.email="build@local" -c user.name="build" commit --allow-empty -m "build" \
    && pnpm run build

EXPOSE 3080

CMD ["pnpm", "dsh", "web", "--no-open", "--host", "0.0.0.0", "--port", "3080"]
