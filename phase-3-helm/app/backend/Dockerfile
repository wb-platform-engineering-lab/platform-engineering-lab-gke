FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
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


