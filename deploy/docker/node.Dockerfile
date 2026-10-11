# Node.js service with a build step (NestJS, or any TypeScript project):
# any folder with package.json and src/. Explained in GUIDE.html, step 5.

ARG RUNTIME_VERSION=22

# Stage 1: install everything and build
FROM node:${RUNTIME_VERSION}-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci --no-fund --no-audit || npm install --no-fund --no-audit

COPY tsconfig*.json* nest-cli.json* ./
COPY src ./src

ARG NEEDS_BUILD=true
RUN if [ "$NEEDS_BUILD" = "true" ]; then npm run build; fi

# Stage 2: run, with production dependencies only
FROM node:${RUNTIME_VERSION}-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev --no-fund --no-audit || npm install --omit=dev --no-fund --no-audit

ARG BUILD_OUTPUT=dist
COPY --from=build /app/${BUILD_OUTPUT} ./${BUILD_OUTPUT}
RUN chown -R node:node /app

ARG APP_PORT=3000
ENV APP_PORT=${APP_PORT} PORT=${APP_PORT}
EXPOSE ${APP_PORT}

USER node

ARG HEALTH_PATH=/
ENV HEALTH_PATH=${HEALTH_PATH}
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD [ -z "$HEALTH_PATH" ] || wget -qO- "http://localhost:${PORT}${HEALTH_PATH}" >/dev/null || exit 1

ARG START_CMD="node dist/main.js"
ENV START_CMD=${START_CMD}
ENTRYPOINT ["sh", "-c", "$START_CMD"]
