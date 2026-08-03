# Colmena backend — Django (python:3.10, matches the pyenv 3.10 the host path uses).
# Build context is the repo ROOT (see docker-compose.yml), so this can read both
# backend/ and docker/. Installs dev requirements into the image so the container
# needs no host toolchain. Seed/migrate/runserver live in backend-entrypoint.sh.
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Build deps for psycopg2 / compiled wheels, plus curl + make for the entrypoint.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev curl make tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache) — requirements/dev.txt is the dev env.
COPY backend/requirements/ requirements/
RUN pip install -r requirements/dev.txt

# Copy the backend source.
COPY backend/ .

# Entrypoint + the verbatim NC seed + user-creation scripts.
COPY docker/backend-entrypoint.sh /usr/local/bin/backend-entrypoint.sh
COPY docker/seed_nextcloud.py /app/docker/seed_nextcloud.py
COPY docker/create_users.py /app/docker/create_users.py
RUN chmod +x /usr/local/bin/backend-entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["backend-entrypoint.sh"]
