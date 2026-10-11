# Angular (or any npm-built single-page app), served by nginx on port 80.
# Either the app reads its API addresses from /app-config.js (two small edits,
# GUIDE.html step 5), or PROXY_ROUTES sends the API paths on to the services
# so the page calls its own address and needs no edit.

ARG RUNTIME_VERSION=22

# Stage 1: build the static files
FROM node:${RUNTIME_VERSION}-alpine AS build
# No questions during the build: the Angular CLI otherwise waits for an answer
# to its usage-data prompt and the build never finishes.
ENV CI=true NG_CLI_ANALYTICS=false
# An image build never has the runtime secrets. Bundle checks that compare the build against
# them (scripts/check-bundle-secrets.mjs) still scan, but skip the values that are not set.
ENV ALLOW_MISSING_SECRET_VALUES=1
# MODULE is the app's folder inside the build context: "." normally; with
# build_from (an app that reads a Config folder above it) the context is the
# parent and MODULE the path down to the app.
ARG MODULE=.
WORKDIR /src/${MODULE}

COPY ${MODULE}/package*.json ./
RUN npm ci --no-fund --no-audit --ignore-scripts || npm install --no-fund --no-audit --ignore-scripts

COPY . /src
# prebuild: folders of the build context the app's build scripts need with
# their own node_modules (for example a shared config/ tool).
ARG PREBUILD=""
RUN for d in $PREBUILD; do (cd "/src/$d" && (npm ci --no-audit --no-fund || npm install --no-audit --no-fund)); done
# Dependencies were installed without their scripts (the sources were not there
# yet). Run the project's postinstall now: it often generates the API clients,
# and openapi-generator needs Java for that.
# openapi-generator (in postinstall or in the build itself) needs Java.
RUN if grep -q 'openapi-generator' package.json; then apk add --no-cache openjdk21-jre-headless >/dev/null; fi; \
    if grep -q '"postinstall"' package.json; then \
      npm run postinstall || echo "postinstall failed; continuing (the build shows whether it mattered)"; \
    fi
ARG BUILD_SCRIPT=build
RUN npm run ${BUILD_SCRIPT}

ARG DIST_DIR=dist/*/browser
# Angular 17+ writes dist/<app>/browser; older builders write dist/<app> itself.
# An Angular SSR build names its page index.csr.html; serve it as index.html.
RUN mkdir /site \
    && src=$(ls -d ${DIST_DIR} 2>/dev/null | head -1) \
    && { [ -n "$src" ] || src=$(dirname "$(find dist -name 'index*.html' -not -path '*/server/*' | head -1)"); } \
    && echo "serving $src" && cp -r "$src"/. /site/ \
    && { [ -f /site/index.html ] || cp /site/index.csr.html /site/index.html; } && test -f /site/index.html

# Stage 2: nginx serves the files
FROM nginx:1.27-alpine AS runtime

COPY --from=build /site /usr/share/nginx/html

COPY <<'NGINX' /etc/nginx/conf.d/default.conf
server {
  listen 80;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  location = /app-config.js {
    add_header Cache-Control "no-store";
  }

  location = /index.html {
    add_header Cache-Control "no-cache";
  }

  # API paths sent on to the services (PROXY_ROUTES), so the page and the
  # APIs share one address. Written when the container starts.
  include /etc/nginx/proxy-routes.inc;
}
NGINX

COPY <<'MAP' /etc/nginx/conf.d/00-upgrade.conf
# Lets a proxied path carry a WebSocket.
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
MAP

# Runs when the container starts: writes the API addresses into app-config.js.
COPY --chmod=755 <<'SCRIPT' /docker-entrypoint.d/40-app-config.sh
#!/bin/sh
set -eu
AUTH_URL="${AUTH_URL:-}"
BACKEND_URL="${BACKEND_URL:-}"
cat > /usr/share/nginx/html/app-config.js <<CONFIG
window.__APP_CONFIG__ = {
  authBaseUrl: "${AUTH_URL%/}",
  tradeBaseUrl: "${BACKEND_URL%/}"
};
CONFIG
echo "app-config.js: auth='${AUTH_URL%/}' trade='${BACKEND_URL%/}' (empty = same address as the page)"

# PROXY_ROUTES="/auth=http://auth-service:3000 /api=http://order-service:8081"
: > /etc/nginx/proxy-routes.inc
for route in ${PROXY_ROUTES:-}; do
  path="${route%%=*}"; target="${route#*=}"
  # A target ending in / drops the path's prefix: /trade-api/x -> service/x
  case "$target" in */)
    cat >> /etc/nginx/proxy-routes.inc <<LOCATION
location ${path%/}/ {
  proxy_pass ${target};
  proxy_http_version 1.1;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$connection_upgrade;
  proxy_set_header Host \$http_host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_read_timeout 3600s;
}
LOCATION
    echo "proxy: ${path}/ -> ${target} (prefix dropped)"; continue ;;
  esac
  cat >> /etc/nginx/proxy-routes.inc <<LOCATION
location ~ ^${path%/}(/|\$) {
  proxy_pass ${target%/};
  proxy_http_version 1.1;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$connection_upgrade;
  proxy_set_header Host \$http_host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_read_timeout 3600s;
}
LOCATION
  echo "proxy: ${path} -> ${target}"
done
SCRIPT

EXPOSE 80
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=5 \
    CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
