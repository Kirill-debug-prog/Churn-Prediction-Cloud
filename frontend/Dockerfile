FROM nginx:1.28-alpine

COPY index.html style.css app.js validation.js /usr/share/nginx/html/
COPY config.docker.js /usr/share/nginx/html/config.js
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
