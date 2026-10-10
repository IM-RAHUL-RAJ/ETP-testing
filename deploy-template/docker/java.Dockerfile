# A Spring Boot service, such as order-service (8081) or executor-service (8082).
# 8080 stays free for Jenkins on the build box.
#   docker build -f deploy/docker/java.Dockerfile --build-arg APP_DIR=Services/order-service -t order-service .
#
# CHANGE ME in deploy/.env: ORDER_DIR and EXECUTOR_DIR (the folders with pom.xml).

FROM maven:3.9-eclipse-temurin-21 AS build
ARG APP_DIR=Services/order-service
WORKDIR /src
# The whole repository, so a pom that reads a sibling module or ../../Databases still builds.
COPY . .
WORKDIR /src/${APP_DIR}
RUN mvn -q -B package -DskipTests \
 && cp "$(ls target/*.jar | grep -v -e '-plain.jar$' -e '-sources.jar$' | head -1)" /app.jar

# Ubuntu-based, not Alpine: native libraries (ONNX Runtime, Netty native, Snappy)
# need glibc, which Alpine does not have.
FROM eclipse-temurin:21-jre
ARG PORT=8081
RUN groupadd --system app && useradd --system --gid app --no-create-home app
WORKDIR /app
COPY --from=build --chown=app:app /app.jar app.jar
USER app
ENV SERVER_PORT=${PORT} JAVA_OPTS="-XX:MaxRAMPercentage=75" \
    MANAGEMENT_HEALTH_MAIL_ENABLED=false
# MANAGEMENT_HEALTH_MAIL_ENABLED=false: a mail server outage (or no mail login yet)
# must not mark the service down in Docker or Kubernetes.
EXPOSE ${PORT}
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=5 \
  CMD wget -qO- "http://127.0.0.1:${SERVER_PORT}/actuator/health" >/dev/null || exit 1
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
