FROM node:18-alpine

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --omit=dev

COPY my_server ./my_server

ENV NODE_ENV=production

EXPOSE 8080

CMD ["npm", "start"]
