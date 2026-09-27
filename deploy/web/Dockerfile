FROM nginx:stable-alpine

COPY deploy/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY dist/web/ /usr/share/nginx/html/

RUN nginx -t

EXPOSE 80
