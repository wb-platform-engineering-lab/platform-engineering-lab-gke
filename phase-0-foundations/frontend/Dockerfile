# Stage 1 — build: install dependencies
FROM node:20-slim AS builder

WORKDIR /app

COPY package.json .
RUN npm install --production

# Stage 2 — runtime: copy only what we need
FROM node:20-slim

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY app.js .
COPY package.json .

EXPOSE 3000

CMD ["node", "app.js"]
