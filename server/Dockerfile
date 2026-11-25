FROM node:24-alpine
WORKDIR /app
COPY src ./src
COPY pages ./pages
ENV NODE_ENV=production PORT=8787 DB_PATH=/data/murmure.db
USER node
EXPOSE 8787
CMD ["node", "--disable-warning=ExperimentalWarning", "src/server.mjs"]
