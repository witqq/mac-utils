# syntax=docker/dockerfile:1.7

# Registry-verified 2026-08-11. The digest pins the multi-platform image index.
FROM nginxinc/nginx-unprivileged:1.31.3-alpine3.24@sha256:334d92979f15aaecd5dd50af5105e1230e2bb70765d45b1e2f964e7c5eda81c3

USER root
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
RUN rm -rf /usr/share/nginx/html/*
COPY website/index.html website/styles.css website/app.js /usr/share/nginx/html/
COPY website/assets/ /usr/share/nginx/html/assets/
RUN find /usr/share/nginx/html -type d -exec chmod 755 {} + \
  && find /usr/share/nginx/html -type f -exec chmod 644 {} +

USER 101
EXPOSE 4080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["wget", "-qO-", "http://127.0.0.1:4080/health"]
