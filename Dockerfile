# Production all-in-one image — multi-stage, non-root.
#
# One container runs the whole app: nginx fronts it on :5000, routing /api/* to
# the NestJS backend (127.0.0.1:3000, /api prefix stripped), /uploads/* to the
# uploads volume, and everything else to the Next.js frontend prod server
# (127.0.0.1:4200). The three processes are spawned by docker/entrypoint.sh
# (plain bash `&` + `wait -n` + signal trap — deliberately no PM2; if any
# process dies the entrypoint exits and the orchestrator restarts the
# container). This matches the contract of the root docker-compose.yaml, which
# publishes 4007:5000 and points the browser at NEXT_PUBLIC_BACKEND_URL
# http://localhost:4007/api.
#
# Differs from docker/Dockerfile.dev (which bundled devDeps + ran nginx + PM2 as
# root): this builds in a throwaway stage, prunes dev dependencies, and the
# runtime stage runs as an unprivileged user.

FROM node:24.19.0-bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    make \
    python3-pip \
    bash \
    ca-certificates \
&& rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_DOWNLOAD=1
RUN npm --no-update-notifier --no-fund --global install pnpm@10.34.4

WORKDIR /app
COPY . /app

# pnpm 10 blocks dependency lifecycle scripts unless explicitly approved.
# The upstream workspace uses both onlyBuiltDependencies and allowBuilds;
# onlyBuiltDependencies can restrict the newer allowBuilds map, so remove that
# legacy list and ensure the required native/installer packages are present in
# the allowBuilds map. Existing entries are left untouched to avoid duplicate YAML keys.
RUN sed -i '/^onlyBuiltDependencies:/,/^allowBuilds:/{ /^allowBuilds:/!d; }' pnpm-workspace.yaml \
 && grep -q "^  '@firebase/util':" pnpm-workspace.yaml || printf "  '@firebase/util': true\n" >> pnpm-workspace.yaml \
 && grep -q "^  'ffmpeg-static':" pnpm-workspace.yaml || printf "  'ffmpeg-static': true\n" >> pnpm-workspace.yaml \
 && grep -q "^  puppeteer:" pnpm-workspace.yaml || printf "  puppeteer: true\n" >> pnpm-workspace.yaml \
 && pnpm install --frozen-lockfile

ENV NEXT_PUBLIC_BACKEND_URL=https://backend-url-not-set.postmill.invalid/api
RUN NODE_OPTIONS="--max-old-space-size=4096" pnpm run build \
 && rm -rf apps/frontend/.next/cache

RUN CI=true pnpm prune --prod

FROM node:24.19.0-bookworm-slim AS runtime

ARG NEXT_PUBLIC_VERSION
ENV NEXT_PUBLIC_VERSION=$NEXT_PUBLIC_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    chromium \
    ffmpeg \
    fonts-liberation \
    fonts-dejavu-core \
    libcairo2 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libjpeg62-turbo \
    libgif7 \
    librsvg2-2 \
    ca-certificates \
    curl \
&& rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_DOWNLOAD=1
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV NODE_ENV=production
ENV TZ=UTC
ENV PORT=3000

RUN addgroup --system app \
 && adduser --system --ingroup app --home /app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=app:app /app /app

USER app

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS http://127.0.0.1:5000/api/health/live || exit 1

ENTRYPOINT ["bash", "/app/docker/entrypoint.sh"]
