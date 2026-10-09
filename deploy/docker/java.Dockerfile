# Java service built with Maven: any folder with pom.xml and src/ that
# produces one runnable Spring Boot jar. Explained in GUIDE.html, step 5.
#
# Two optional build arguments, both set by config/apply.py from project.yaml:
#   MODULE    the service's folder inside the build context. "." (the default)
#             when the context is the service folder itself.
#   PREBUILD  folders in the context to `mvn install` first, for a service that
#             compiles against another service or a shared module.

# Stage 1: compile
ARG RUNTIME_VERSION=21
FROM maven:3.9.9-eclipse-temurin-${RUNTIME_VERSION} AS builder
WORKDIR /app

ARG MODULE=.
ARG PREBUILD=""
COPY . .
RUN --mount=type=cache,target=/root/.m2 \
    set -e; \
    for p in $PREBUILD; do mvn -B -q -f "$p/pom.xml" install -DskipTests; done; \
    mvn -B -q -f "$MODULE/pom.xml" package -DskipTests

# A project can also produce a plain jar or a classified one (such as *-exec.jar).
# The runnable one is the jar with BOOT-INF/ inside. A plain Java service
# (no Spring Boot) sets MAIN_CLASS: its jar and its runtime dependencies are copied.
ARG MAIN_CLASS=""
RUN --mount=type=cache,target=/root/.m2 \
    set -e; mkdir -p /lib; \
    if [ -n "$MAIN_CLASS" ]; then \
      cp "$(ls "$MODULE"/target/*.jar | grep -vE -- '-(sources|javadoc|tests)\.jar$' | head -1)" /app.jar; \
      mvn -B -q -f "$MODULE/pom.xml" dependency:copy-dependencies -DincludeScope=runtime -DoutputDirectory=/lib; \
    else \
      for j in "$MODULE"/target/*.jar; do \
        if jar tf "$j" | grep -q '^BOOT-INF/'; then cp "$j" /app.jar; echo "runnable jar: $j"; break; fi; \
      done; \
    fi; \
    test -f /app.jar || { echo "No Spring Boot jar in $MODULE/target (set main_class for a plain Java service)" >&2; exit 1; }

# Stage 2: run
ARG RUNTIME_VERSION=21
FROM eclipse-temurin:${RUNTIME_VERSION}-jre-alpine AS runtime
WORKDIR /app

# /app belongs to the app user, so a service that writes logs/ or other files
# next to itself can create them.
RUN addgroup -S app && adduser -S app -G app && chown app:app /app
COPY --from=builder --chown=app:app /app.jar /app/app.jar
COPY --from=builder --chown=app:app /lib /app/lib
ARG MAIN_CLASS=""
ENV MAIN_CLASS=${MAIN_CLASS}

ARG APP_PORT=8080
ENV APP_PORT=${APP_PORT} SERVER_PORT=${APP_PORT}
EXPOSE ${APP_PORT}
ENV JAVA_OPTS=""

USER app

ARG HEALTH_PATH=/actuator/health
ENV HEALTH_PATH=${HEALTH_PATH}
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD [ -z "$HEALTH_PATH" ] || wget -qO- "http://localhost:${SERVER_PORT}${HEALTH_PATH}" >/dev/null || exit 1

ENTRYPOINT ["sh", "-c", "if [ -n \"$MAIN_CLASS\" ]; then exec java $JAVA_OPTS -cp '/app/app.jar:/app/lib/*' \"$MAIN_CLASS\"; else exec java $JAVA_OPTS -jar /app/app.jar; fi"]
