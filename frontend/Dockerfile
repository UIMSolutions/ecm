FROM docker.io/nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
# the OpenUI5 app lives in the root of frontend/ (no webapp/ folder)
COPY index.html Component.js manifest.json /usr/share/nginx/html/
COPY view /usr/share/nginx/html/view
COPY controller /usr/share/nginx/html/controller
COPY model /usr/share/nginx/html/model
COPY i18n /usr/share/nginx/html/i18n
# Backend base URL without trailing slash; proxied under /odata/
ENV BACKEND_URL=http://backend:8080
EXPOSE 8080
