FROM node:20-slim AS builder
WORKDIR /app
COPY package.json .
RUN npm install --production

FROM node:20-slim
# Upgrade OS packages and npm itself — npm bundles tar/glob/minimatch internally
# and older npm versions carry CVEs in those bundled packages
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
EXPOSE 3000
CMD ["node", "app.js"]
