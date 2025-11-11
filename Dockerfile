# Simple Dockerfile example
FROM nginx:alpine
COPY myapp /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
