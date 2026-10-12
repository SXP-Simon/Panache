# 先执行 flutter build web --release；CI 在 Docker build 之前完成此步骤。
FROM nginx:stable-alpine
COPY build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
