FROM nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY healthcheck.ps1 /usr/share/nginx/html/healthcheck.ps1
COPY web/index.html /usr/share/nginx/html/index.html

EXPOSE 80
