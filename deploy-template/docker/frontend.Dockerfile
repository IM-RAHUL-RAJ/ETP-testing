# Angular page served by nginx. nginx also forwards /auth and /api to the services
# (docker/frontend-nginx.conf), so the browser only ever calls the page's own address
# and the same image works on the box, on EKS and behind the load balancer.
#
# Built from the repository root, so the build can see Config/, Contracts/ or a root .env
# if your frontend reads them:
#   docker build -f deploy/docker/frontend.Dockerfile --build-arg APP_DIR=Frontend/trading-ui -t frontend .
#
# CHANGE ME: APP_DIR in deploy/.env (FRONTEND_DIR), the folder that holds package.json.

FROM node:22-alpine AS build
# No questions during the build: the Angular CLI otherwise waits for an answer
# to its usage-data prompt and the build never finishes.
ENV CI=true NG_CLI_ANALYTICS=false
# A build never has the runtime secrets; bundle checks that compare against them
# (check-bundle-secrets.mjs) skip the values that are not set.
ENV ALLOW_MISSING_SECRET_VALUES=1
ARG APP_DIR=Frontend
WORKDIR /src
COPY . .
WORKDIR /src/${APP_DIR}
# openapi-generator (API clients generated at install or build time) needs Java.
RUN if grep -q 'openapi-generator' package.json; then apk add --no-cache openjdk21-jre-headless >/dev/null; fi
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
RUN npm run build
# Angular 17+ writes dist/<app>/browser; older builders write dist/<app> itself.
RUN mkdir /site \
    && src=$(ls -d dist/*/browser 2>/dev/null | head -1) \
    && { [ -n "$src" ] || src=$(dirname "$(find dist -name 'index*.html' -not -path '*/server/*' | head -1)"); } \
    && echo "serving $src" && cp -r "$src"/. /site/ \
    && { [ -f /site/index.html ] || cp /site/index.csr.html /site/index.html; } && test -f /site/index.html

FROM nginx:1.27-alpine
COPY deploy/docker/frontend-nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /site /usr/share/nginx/html
EXPOSE 80
# 127.0.0.1, not localhost: localhost resolves to IPv6 first inside the image.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=5 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
