FROM node:18-alpine
WORKDIR /app
COPY server.js .
EXPOSE 8081
CMD ["node", "server.js"]
