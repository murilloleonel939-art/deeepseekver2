# Este despliegue: qué hay, dónde está y cómo se recupera

Documento para que cualquier chat nuevo —o tú mismo dentro de seis meses— sepa
dónde está todo sin tener que reconstruirlo.

## El repositorio

| Dato | Valor |
|---|---|
| Repositorio | `github.com/murilloleonel939-art/deeepseekver2` |
| Rama de despliegue | `main` |
| Acceso | token de GitHub con lectura, escritura y workflows |
| Dónde vive el token | `/root/.ghauth/token` (permisos `600`, fuera del repo) |

**El token no está en el repositorio, y no debe estarlo.** Vive solo en el
volumen persistente `/root`. Si se pierde el volumen, hay que volver a crearlo
desde GitHub y pegarlo otra vez en esa ruta.

Leerlo:

```bash
cat /root/.ghauth/token
```

Usarlo para clonar, sin dejarlo escrito en la configuración de git:

```bash
TOKEN=$(cat /root/.ghauth/token)
git clone "https://x-access-token:${TOKEN}@github.com/murilloleonel939-art/deeepseekver2.git" repo
cd repo && git remote set-url origin https://github.com/murilloleonel939-art/deeepseekver2.git
```

Si el token se filtra, se revoca desde GitHub y se sustituye el contenido del
archivo. El repo es público, así que el token es la única llave de escritura.

## Qué hay en el repositorio

En la raíz: `Dockerfile`, `entrypoint.sh` y la carpeta `deploy/`.

| Archivo | Para qué sirve |
|---|---|
| `Dockerfile` | Imagen base, `unzip`, `python3-venv`, y arranque por `entrypoint.sh` |
| `entrypoint.sh` | Restaura todo lo que falte en el volumen y arranca la app |
| `deploy/skills.tar.gz` | Los 67 skills. Fuente de verdad de `/root/.agents/skills` |
| `deploy/SKILLS-MANIFEST.md` | Lista legible de esos skills |
| `deploy/llm-shim.py` | Endpoint compatible con OpenAI para claude-mem, fijado a `gpt-6-luna` |
| `deploy/patch-claude-mem-adapter.js` | Añade el ciclo de vida de sesiones al adaptador de claude-mem |
| `deploy/install-scan-tools.sh` | Instala los 8 escáneres de seguridad |
| `deploy/README.md` | Documentación técnica de todo lo anterior |

Cada `git push` a `main` dispara el workflow *Build image*, que publica
`ghcr.io/murilloleonel939-art/deeepseekver2:latest`. Coolify despliega desde ahí.

## Qué hay instalado, y dónde

Todo lo instalado vive en `/root`, que es el volumen persistente. `/app` es la
imagen y se reconstruye en cada despliegue: nunca guardes nada ahí.

| Ruta | Contenido |
|---|---|
| `/root/.agents/skills` | 67 skills |
| `/root/.venvs/graphify` | graphify, para grafos de conocimiento del código |
| `/root/.venvs/sec` | semgrep y guarddog |
| `/root/.local/bin` | gitleaks, trivy, syft, grype, cosign, opa, y los enlaces de graphify |
| `/root/.cache/ms-playwright` | Chromium para el skill de Playwright |
| `/root/.bun` | Bun, que necesita claude-mem |
| `/root/.npm-global` | claude-mem y su adaptador |
| `/root/.claude-mem` | Base de datos y configuración de claude-mem |
| `/root/.llm-shim` | Log del shim de modelos |
| `/root/.dsh` | Perfiles, credenciales y sesiones de DSH |
| `/root/proyectos` | Aquí van los proyectos. Vacío salvo pruebas |

## El modelo que usa claude-mem

`gpt-6-luna`, del proveedor `pateway2gpt`. La clave está en
`/root/.dsh/.credentials.yaml` bajo `PATEWAY2GPT_API_KEY`, y el shim la lee en
cada petición: nunca se copia a otro archivo ni se registra en el log.

El modelo está fijado en **una sola línea**, `SHIM_MODEL` en `entrypoint.sh`. El
shim sobrescribe cualquier modelo que le pidan, verificado pidiendo otro y
recibiendo `gpt-6-luna`.

Cada resumen cuesta unos 5.900 tokens de entrada. Se dispara al cerrar sesión,
no en cada mensaje.

## Cómo se recupera todo tras un despliegue

`entrypoint.sh` corre en cada arranque. Cada paso se salta si ya está hecho, así
que un volumen caliente no hace trabajo de red.

1. **Skills** — compara el SHA-256 de `deploy/skills.tar.gz` con
   `/root/.agents/skills/.bundle-sha256`. Si difieren, descomprime. Eso cubre
   volumen borrado *y* bundle actualizado.
2. **Bun**, **claude-mem**, **shim**, **adaptador con su parche**, **graphify**,
   **Playwright**, **escáneres**.

Comprobarlo todo sin cambiar nada:

```bash
/app/entrypoint.sh --check      # exit 0 = todo presente
```

## Los dos fallos que costaron más, y su causa

**La memoria no aparecía entre chats.** claude-mem solo inyecta sesiones
cerradas. El adaptador de DSH nunca llamaba a `sessions/init` ni cerraba nada.
Ahora registra en el primer `agent/pre-step` y cierra por inactividad a los 30
minutos o al liberar el agente.

**Los resúmenes hablaban de «dsh session».** El adaptador registraba la sesión
con un texto de relleno, y claude-mem guarda literalmente lo que recibe. Ahora
registra con el primer mensaje real del usuario, extraído de `agent/pre-step`.

## Reglas que conviene no olvidar

- Nunca montar un volumen en `/app`: ocultaría la aplicación y el contenedor no
  arrancaría.
- Nunca guardar el token en un archivo versionado.
- El bundle excluye `node_modules` a propósito: son 19 MB reinstalables y el
  tarball se queda en 4,5 MB.
- Tras cambiar el parche o los skills, hay que **redesplegar** para que el
  proceso DSH los cargue; el archivo en disco no basta.
