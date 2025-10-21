# Use the official Nginx image
FROM nginx:latest

# Remove the default nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy our custom HTML into the web directory
COPY index.html /usr/share/nginx/html/

# Expose port 80
EXPOSE 80

# Start NGINX automatically
CMD ["nginx", "-g", "daemon off;"]
