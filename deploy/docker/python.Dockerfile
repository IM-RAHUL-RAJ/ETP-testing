# Python service (Flask, FastAPI, a plain script): any folder with
# requirements.txt and one entry file. Explained in GUIDE.html, step 5.

ARG RUNTIME_VERSION=3.11
FROM python:${RUNTIME_VERSION}-slim
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN groupadd -r appuser && useradd -r -g appuser appuser \
    && chown -R appuser:appuser /app
USER appuser

ARG APP_PORT=5000
ENV APP_PORT=${APP_PORT}
EXPOSE ${APP_PORT}

ARG HEALTH_PATH=/
ENV HEALTH_PATH=${HEALTH_PATH}
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD [ -z "$HEALTH_PATH" ] || python -c \
        'import os, urllib.request; urllib.request.urlopen("http://localhost:" + os.environ["APP_PORT"] + os.environ["HEALTH_PATH"], timeout=3)' \
        || exit 1

ARG APP_ENTRY="python app.py"
ENV APP_ENTRY=${APP_ENTRY}
ENTRYPOINT ["sh", "-c", "$APP_ENTRY"]
