# 先从仓库根目录执行 python3 scripts/build-flutter-web.py；CI 在 Docker build 之前完成此步骤。
FROM nginx:stable-alpine
COPY build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
