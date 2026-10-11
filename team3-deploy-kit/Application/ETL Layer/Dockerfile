# ==============================================================================
# Generic Dockerfile: Python service or worker (Flask, FastAPI, an ETL loop):
# any folder with requirements.txt and an entry file.
#
# Knobs (all optional, --build-arg or docker-compose `args:`):
#   PYTHON_VERSION  interpreter version                                 (3.12)
#   APP_ENTRY       command that starts it                              (python main.py)
#   APP_PORT        port it listens on; "" for a worker with no port    ("")
#   HEALTH_PATH     HTTP path answering 200; empty = no HTTP check      ("")
#   DATA_DIR        a folder it writes to (e.g. a DuckDB file), made
#                   writable for the app user; mount a volume there     (/data)
# ==============================================================================

ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
ARG DATA_DIR=/data
RUN useradd --create-home app \
 && mkdir -p "${DATA_DIR}" \
 && chown -R app:app /app "${DATA_DIR}"
USER app

ARG APP_PORT=""
ARG HEALTH_PATH=""
ARG APP_ENTRY="python main.py"
ENV APP_PORT=${APP_PORT} HEALTH_PATH=${HEALTH_PATH} APP_ENTRY=${APP_ENTRY}

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD [ -z "$HEALTH_PATH" ] || python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:'+os.environ['APP_PORT']+os.environ['HEALTH_PATH'], timeout=3)" || exit 1

ENTRYPOINT ["sh", "-c", "exec $APP_ENTRY"]
