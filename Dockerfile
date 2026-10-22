FROM alpine:latest

# Install OpenSSL, bash, xxd, and client tools
RUN apk add --no-cache \
    openssl \
    bash \
    xxd \
    curl \
    ca-certificates

# Create serve directory and volume mount point
RUN mkdir -p /srv/www /certs

WORKDIR /srv/www

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4433

ENTRYPOINT ["/entrypoint.sh"]
