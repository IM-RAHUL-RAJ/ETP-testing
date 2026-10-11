# ==============================================================================
# Generic Dockerfile: Java service built with Maven (Spring Boot or any runnable jar)
#
# The same file works for every Java service in every project: nothing in it
# names a project, a package or a jar. Copy it next to any pom.xml.
#
# Knobs (all optional, pass with --build-arg or in docker-compose `args:`):
#   JAVA_VERSION   JDK/JRE major version; match <java.version> in pom.xml  (21)
#   APP_PORT       port the app listens on. Also exported as SERVER_PORT,
#                  which Spring Boot obeys over application.yml           (8080)
#   HEALTH_PATH    HTTP path that answers 200 without a login, e.g.
#                  /health or /actuator/health. Empty = only check that
#                  the port is open (for services with no such endpoint)   ("")
#   MAVEN_ARGS     extra Maven flags                                       ("")
#
# Runtime (docker run -e / compose environment / Kubernetes env):
#   JAVA_OPTS      JVM flags, e.g. -Xmx512m                     (container-aware default)
# ==============================================================================

ARG JAVA_VERSION=21

# ---------- Stage 1: compile ----------
FROM maven:3.9.9-eclipse-temurin-${JAVA_VERSION} AS build
WORKDIR /src
ARG MAVEN_ARGS=""

# pom.xml first: the dependency download is cached until pom.xml changes.
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline ${MAVEN_ARGS} || true

COPY src ./src
# Tests belong in CI, not in the image build.
RUN mvn -B -q package -DskipTests ${MAVEN_ARGS} \
 && JAR=$(ls target/*.jar | grep -v -E '(-sources|-javadoc|-plain)\.jar$' | head -n 1) \
 && test -n "$JAR" && cp "$JAR" /app.jar

# ---------- Stage 2: run on a JRE only ----------
FROM eclipse-temurin:${JAVA_VERSION}-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=build --chown=app:app /app.jar /app/app.jar

ARG APP_PORT=8080
ARG HEALTH_PATH=""
ENV APP_PORT=${APP_PORT} \
    SERVER_PORT=${APP_PORT} \
    HEALTH_PATH=${HEALTH_PATH} \
    JAVA_OPTS="-XX:MaxRAMPercentage=75"
EXPOSE ${APP_PORT}
USER app

HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
  CMD if [ -n "$HEALTH_PATH" ]; then wget -qO- "http://127.0.0.1:${SERVER_PORT}${HEALTH_PATH}" >/dev/null; \
      else nc -z 127.0.0.1 "${SERVER_PORT}"; fi || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
