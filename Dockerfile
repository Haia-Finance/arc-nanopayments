# syntax=docker/dockerfile:1

# ---------- deps: install node_modules from lockfile ----------
FROM node:22-alpine AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

# ---------- builder: compile the Next.js app ----------
FROM node:22-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* values are inlined into the client bundle at build time,
# so they must be present here, not only at runtime.
# Defaults keep a plain `docker build .` from crashing at import-time client
# construction; real values come via --build-arg.
ARG NEXT_PUBLIC_SUPABASE_URL=https://placeholder.supabase.co
ARG NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=placeholder
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL
ENV NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
ENV NEXT_TELEMETRY_DISABLED=1

# Some modules instantiate the Supabase/gateway clients at import time, which
# Next evaluates while collecting page data. These placeholders only satisfy that
# build step (they stay in this stage, never the final image); real server-side
# secrets are injected at runtime via the container env.
ENV SUPABASE_SERVICE_ROLE_KEY=build-placeholder
ENV SELLER_ADDRESS=0x0000000000000000000000000000000000000000

RUN npm run build

# ---------- runner: minimal standalone server ----------
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# tini reaps zombies and forwards signals so SIGTERM triggers a clean shutdown
# (PID 1 has no default signal handlers); libc6-compat covers any glibc addon.
RUN apk add --no-cache tini libc6-compat \
  && addgroup -g 1001 -S nodejs \
  && adduser -u 1001 -S nextjs -G nodejs

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
