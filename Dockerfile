FROM node:24-slim

# Habilitar corepack para usar la versión exacta de pnpm del proyecto
RUN corepack enable

WORKDIR /app
COPY . .

# Instalar dependencias y compilar artefactos
RUN pnpm install --frozen-lockfile
RUN pnpm run build

EXPOSE 3080

# Iniciar servidor web sin abrir navegador y escuchando en todas las interfaces
CMD ["pnpm", "dsh", "web", "--no-open", "--host", "0.0.0.0", "--port", "3080"]
