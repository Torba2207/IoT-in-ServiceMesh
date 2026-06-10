FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
# Populate ${NGINX_LOCAL_RESOLVERS} from /etc/resolv.conf so the templated
# config can resolve the upstream lazily via the cluster DNS.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY --from=builder /app/dist /usr/share/nginx/html
COPY default.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
