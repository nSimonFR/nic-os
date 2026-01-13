FROM node:20-alpine
RUN apk add --no-cache git
RUN corepack enable
WORKDIR /app
COPY package.json yarn.lock tsconfig.json ./
COPY src ./src
RUN yarn install && yarn build
ENV NODE_ENV=production
CMD ["node", "dist/index.js"]
