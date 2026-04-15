FROM node:20-slim AS builder
WORKDIR /app
COPY package.json .
RUN npm install --production

# hadolint ignore=DL3006
FROM gcr.io/distroless/nodejs20-debian12
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js package.json ./
EXPOSE 3000
# distroless entrypoint is node — pass the script directly
CMD ["app.js"]
