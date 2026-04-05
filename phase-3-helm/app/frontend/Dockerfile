FROM node:20-slim AS builder
WORKDIR /app
COPY package.json .
RUN npm install --production

FROM node:20-slim
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
EXPOSE 3000
CMD ["node", "app.js"]
