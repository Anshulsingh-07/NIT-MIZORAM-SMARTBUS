FROM node:18-alpine

# create app directory
WORKDIR /usr/src/app

# install dependencies
COPY package*.json ./
RUN npm ci --only=production

# copy source
COPY . ./

ENV NODE_ENV=production

EXPOSE 8080

CMD ["node", "server.js"]
FROM node:18-slim

# Create app directory
WORKDIR /usr/src/app

# Install small utility (netcat) and app dependencies
RUN apt-get update && apt-get install -y netcat-openbsd && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm install --production --silent

# Bundle app source
COPY . .

EXPOSE 8080

CMD ["node", "server.js"]
