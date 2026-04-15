FROM node:20-slim AS builder
WORKDIR /app
COPY package.json .
RUN npm install --production

FROM node:20-slim
# Upgrade OS packages to pick up all available security patches (e.g. libssl3)
# hadolint ignore=DL3005
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
# Non-root user
RUN groupadd -g 1000 appuser && useradd -u 1000 -g appuser -s /sbin/nologin -M appuser
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
RUN chown -R appuser:appuser /app
USER appuser
EXPOSE 3000
CMD ["node", "app.js"]
