FROM node:24-slim

# python3-venv lets the entrypoint rebuild the graphify and security-tool venvs
# without apt-get on a fresh volume; curl fetches npm and the scan binaries.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ git ca-certificates curl unzip python3-venv \
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

# Deploy assets. deploy/skills.tar.gz is the source of truth for the skill set:
# the entrypoint extracts it into /root/.agents/skills whenever the volume is
# empty or the bundle changed, so a redeploy cannot lose the skills.
# deploy/install-scan-tools.sh installs gitleaks, trivy, syft, grype, cosign,
# opa, semgrep and guarddog into /root/.local/bin and /root/.venvs/sec.
COPY deploy/ /app/deploy/
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh /app/deploy/install-scan-tools.sh

EXPOSE 3080

ENTRYPOINT ["/app/entrypoint.sh"]
