FROM node:20-slim AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-slim
# Upgrade OS packages (gets latest libssl3 etc.) then remove npm entirely
# so npm's bundled tar/glob/minimatch/cross-spawn CVEs are not present at all.
# hadolint ignore=DL3005,DL3008
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
    && npm uninstall -g npm \
    && rm -rf /usr/lib/node_modules/npm ~/.npm
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["node", "app.js"]
