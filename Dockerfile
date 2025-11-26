# Pinned versions for reproducibility
# Caddy: https://github.com/caddyserver/caddy/releases
# Rate limit plugin: https://github.com/mholt/caddy-ratelimit (no releases, using commit SHA)
FROM caddy:2.10.2-builder AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit@04ea34edc0c4248e542b3f84ef4010c351b1cbd2

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

LABEL org.opencontainers.image.source="https://github.com/Coders-Compass/caddy-with-ratelimit"
LABEL org.opencontainers.image.description="Caddy web server with mholt/caddy-ratelimit plugin for HTTP rate limiting"
LABEL org.opencontainers.image.licenses="MIT"
LABEL maintainer="hungrybluedev"

# Verify the build includes the rate_limit module
RUN caddy list-modules | grep rate_limit
