# Build context is the repository root (fly.toml points here): docker build -f server/Dockerfile .
# Single stage: pnpm's node_modules is a tree of symlinks into node_modules/.pnpm, so copying it
# between stages tends to break workspace links. Dev dependencies are pruned at the end instead.
FROM node:26-slim

RUN npm i -g pnpm@12
WORKDIR /app

# Manifests first so the install layer is cached across source changes.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/scheduler/package.json packages/scheduler/
COPY server/package.json server/
# pnpm 12 refuses to install while esbuild's postinstall (pulled in by tsx, drizzle-kit and
# vitest) is neither allowed nor denied under `allowBuilds` in pnpm-workspace.yaml; on that
# failure it writes a placeholder entry instead of a decision. Nothing at runtime needs esbuild,
# so deny it and retry. Once the repo's pnpm-workspace.yaml decides, the first install succeeds
# and the fallback never runs.
RUN pnpm install --frozen-lockfile \
  || (pnpm approve-builds '!esbuild' && pnpm install --frozen-lockfile)

# Sources only (never the host's node_modules or dist).
COPY packages/scheduler/tsconfig.json packages/scheduler/
COPY packages/scheduler/src packages/scheduler/src
COPY server/tsconfig.json server/
COPY server/src server/src
COPY server/drizzle server/drizzle
RUN pnpm -r build && pnpm prune --prod

ENV NODE_ENV=production PORT=8080 NODE_OPTIONS=--max-old-space-size=192
EXPOSE 8080
CMD ["node", "server/dist/index.js"]
