FROM node:20-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-slim
# Upgrade OS packages to pick up all available security patches (e.g. libssl3)
# hadolint ignore=DL3005
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
# node:20-slim already includes a 'node' user at uid/gid 1000
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["node", "app.js"]
