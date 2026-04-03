# Stage 1 — build: install dependencies into a local folder
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt


# Stage 2 — runtime: copy only what we need
FROM python:3.12-slim

WORKDIR /app

COPY --from=builder /install /usr/local
COPY app.py .

EXPOSE 5000

CMD ["python", "app.py"]
