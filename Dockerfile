FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

LABEL org.opencontainers.image.source="https://github.com/Coders-Compass/caddy-with-ratelimit"
LABEL org.opencontainers.image.description="Caddy web server with mholt/caddy-ratelimit plugin for HTTP rate limiting"
LABEL org.opencontainers.image.licenses="MIT"
LABEL maintainer="hungrybluedev"

# Verify the build includes the rate_limit module
RUN caddy list-modules | grep rate_limit
