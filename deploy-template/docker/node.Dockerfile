# A NestJS (or any Node) service, such as auth-service on port 3000.
#   docker build -f deploy/docker/node.Dockerfile --build-arg APP_DIR=Services/auth-service -t auth-service .
#
# CHANGE ME in deploy/.env: AUTH_DIR (the folder with package.json), and AUTH_ENTRY if
# your build does not write dist/main.js (look in dist/ after `npm run build`).

FROM node:22-alpine AS build
ARG APP_DIR=Services/auth-service
WORKDIR /app
# Native modules (argon2, bcrypt) fall back to compiling when their pre-built
# binary cannot be downloaded; that needs python3, make and g++.
RUN apk add --no-cache python3 make g++ >/dev/null
COPY ${APP_DIR}/package*.json ./
# npm ci needs package-lock.json in step with package.json; fall back to npm install.
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
COPY ${APP_DIR}/ ./
RUN npm run build
# Keep only production dependencies; the runtime copies them instead of installing again.
RUN npm prune --omit=dev --no-fund --no-audit

FROM node:22-alpine
ARG APP_DIR=Services/auth-service
ARG ENTRY=dist/main.js
ARG PORT=3000
WORKDIR /app
ENV NODE_ENV=production PORT=${PORT} ENTRY=${ENTRY}
COPY ${APP_DIR}/package*.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
USER node
EXPOSE ${PORT}
# 127.0.0.1, not localhost: localhost resolves to IPv6 first, and a service that
# listens on 0.0.0.0 would look unhealthy.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=5 \
  CMD wget -qO- "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || wget -S -qO- "http://127.0.0.1:${PORT}/" 2>&1 | grep -q "HTTP/" || exit 1
CMD ["sh", "-c", "exec node $ENTRY"]
