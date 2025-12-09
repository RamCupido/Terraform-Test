# Usamos una imagen ligera de Nginx
FROM nginx:alpine

# Copiamos un index.html personalizado
COPY index.html /usr/share/nginx/html/index.html

# Exponemos el puerto 80
EXPOSE 80