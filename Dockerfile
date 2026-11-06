FROM node:24.22.2-alpine3.24

COPY . .

WORKDIR /usr/src/app/

RUN npm version
