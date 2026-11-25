# Caddy 2.11.7 + Cloudflare DNS module, for DNS-01 certificates on *.home.example.com.
FROM caddy:2.11.7-builder AS builder
RUN xcaddy build v2.11.7 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.7
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
