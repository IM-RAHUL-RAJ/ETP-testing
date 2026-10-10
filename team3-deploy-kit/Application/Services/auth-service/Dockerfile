# ==============================================================================
# Generic Dockerfile: Node.js service (NestJS, Express, any TypeScript or JS app)
#
# Nothing in it names a project. Copy it next to any package.json.
#
# Knobs (all optional, pass with --build-arg or in docker-compose `args:`):
#   NODE_VERSION   Node major version                                     (22)
#   APP_PORT       port the app listens on; also exported as PORT         (3000)
#   BUILD_SCRIPT   npm script that compiles the app; "" for plain JS      (build)
#   BUILD_OUTPUT   folder the build writes; "." for plain JS              (dist)
#   START_CMD      command that starts the app                            (node dist/main.js)
#   HEALTH_PATH    HTTP path that answers 200 without a login; empty =
#                  only check that the port is open                       ("")
# ==============================================================================

ARG NODE_VERSION=22

# ---------- Stage 1: install everything and build ----------
FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /src
COPY package*.json ./
# npm ci needs a lock file that matches package.json; fall back to install.
RUN npm ci --no-fund --no-audit || npm install --no-fund --no-audit
COPY . .
ARG BUILD_SCRIPT=build
RUN if [ -n "$BUILD_SCRIPT" ]; then npm run "$BUILD_SCRIPT"; fi

# ---------- Stage 2: production dependencies + build output ----------
FROM node:${NODE_VERSION}-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN (npm ci --omit=dev --no-fund --no-audit || npm install --omit=dev --no-fund --no-audit) \
 && npm cache clean --force
ARG BUILD_OUTPUT=dist
COPY --from=build /src/${BUILD_OUTPUT} ./${BUILD_OUTPUT}
RUN chown -R node:node /app

ARG APP_PORT=3000
ARG HEALTH_PATH=""
ARG START_CMD="node dist/main.js"
ENV APP_PORT=${APP_PORT} PORT=${APP_PORT} HEALTH_PATH=${HEALTH_PATH} START_CMD=${START_CMD}
EXPOSE ${APP_PORT}
USER node

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD if [ -n "$HEALTH_PATH" ]; then wget -qO- "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null; \
      else nc -z 127.0.0.1 "${PORT}"; fi || exit 1

ENTRYPOINT ["sh", "-c", "exec $START_CMD"]
