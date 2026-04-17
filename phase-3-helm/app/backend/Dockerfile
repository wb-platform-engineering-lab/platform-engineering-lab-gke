FROM python:3.12-slim AS builder
WORKDIR /app
# Build deps for psycopg2 (non-binary) — compiles against the system's OpenSSL
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libc-dev libpq-dev \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
# Upgrade OS packages + install libpq5 (runtime shared lib for psycopg2 non-binary)
# hadolint ignore=DL3005,DL3008
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*
# Create non-root user matching securityContext runAsUser: 1000
RUN groupadd -g 1000 appuser && useradd -u 1000 -g appuser -s /sbin/nologin -M appuser
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin/flask /usr/local/bin/flask
COPY app.py .
RUN chown appuser:appuser /app
# Prevent Python from writing .pyc files (incompatible with readOnlyRootFilesystem)
ENV PYTHONDONTWRITEBYTECODE=1
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]


