# ==============================================================================
# Generic Dockerfile: Angular (or React/Vue: any npm-built single-page app),
# served by nginx on port 80.
#
# The API addresses are NOT baked into the image. When the container starts it
# writes /app-config.js from environment variables, so one image works on a
# laptop, on EC2, behind four load balancers or behind one Ingress. The app
# loads that file from index.html (a one-time code change, see GUIDE.html).
#
# Knobs (all optional, --build-arg or docker-compose `args:`):
#   NODE_VERSION    Node major version for the build                    (22)
#   BUILD_SCRIPT    npm script that builds the production bundle        (build)
#   BUILD_ENV       VAR=value pairs the build step needs, space separated
#                   (e.g. a project script that refuses to build without
#                   an API URL). Only fallbacks: runtime values win.      ("")
#
# Runtime (docker run -e / compose environment / Kubernetes env):
#   RUNTIME_CONFIG  which window.__APP_CONFIG__ key is filled from which
#                   environment variable, "key:VAR,key:VAR"
#                   (authApiUrl:AUTH_SERVICE_URL,tradeApiUrl:ORDER_SERVICE_URL)
#   AUTH_SERVICE_URL, ORDER_SERVICE_URL (or whatever RUNTIME_CONFIG names)
#                   unset  = keep the address built into the bundle
#                   ""     = same address as the page (one load balancer / CloudFront)
#                   a URL  = call that address (four load balancers, EC2 public IP)
# ==============================================================================

ARG NODE_VERSION=22

# ---------- Stage 1: build the static files ----------
FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /src
COPY package*.json ./
RUN npm ci --no-fund --no-audit || npm install --no-fund --no-audit
COPY . .
ARG BUILD_SCRIPT=build
ARG BUILD_ENV=""
RUN env ${BUILD_ENV} npm run "${BUILD_SCRIPT}" \
 # Angular 17+ writes dist/<name>/browser, older Angular dist/<name>, React build/, Vue dist/.
 && INDEX=$(find dist build -name index.html -not -path '*/server/*' 2>/dev/null | head -n 1) \
 && test -n "$INDEX" && mkdir /site && cp -r "$(dirname "$INDEX")"/. /site/

# ---------- Stage 2: nginx ----------
FROM nginx:1.27-alpine
COPY --from=build /site /usr/share/nginx/html

COPY <<'NGINX' /etc/nginx/conf.d/default.conf
server {
  listen 80;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;

  # Client-side routes (/dashboard, /admin/...) get the app, which routes them.
  location / {
    try_files $uri $uri/ /index.html;
  }
  # Written at container start: never cache it.
  location = /app-config.js {
    add_header Cache-Control "no-store";
  }
  location = /index.html {
    add_header Cache-Control "no-cache";
  }
  # Hashed bundles never change.
  location ~* \.(js|css|woff2?|svg|png|jpg|ico)$ {
    expires 1y;
    add_header Cache-Control "public, immutable";
  }
}
NGINX

# nginx runs every script in /docker-entrypoint.d/ before it starts.
COPY --chmod=755 <<'SCRIPT' /docker-entrypoint.d/40-app-config.sh
#!/bin/sh
set -eu
out=/usr/share/nginx/html/app-config.js
body=""
IFS=','
for pair in ${RUNTIME_CONFIG}; do
  key="${pair%%:*}"; var="${pair#*:}"
  # Only variables that are set; an empty value is kept (= same address as the page).
  if eval "[ \"\${${var}+set}\" = set ]"; then
    value="$(eval "printf '%s' \"\${${var}}\"")"
    body="${body}  \"${key}\": \"${value%/}\",
"
  fi
done
printf 'window.__APP_CONFIG__ = {\n%s\n};\n' "$(printf '%s' "$body" | sed '$ s/,$//')" > "$out"
echo "app-config.js:"; cat "$out"
SCRIPT

ENV RUNTIME_CONFIG="authApiUrl:AUTH_SERVICE_URL,tradeApiUrl:ORDER_SERVICE_URL"
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=5 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
