# Caddy with Rate Limiting

A production-ready Caddy web server Docker image with the [mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) plugin pre-installed for HTTP rate limiting capabilities.

## Features

- **Base**: Official Caddy 2 image
- **Rate Limiting**: mholt/caddy-ratelimit plugin included
- **Multi-arch**: Supports both amd64 and arm64
- **Auto-updates**: Weekly automated builds on Sundays to get latest security patches
- **Production-ready**: Built with xcaddy using stable, tested versions

## Usage

### Quick Start

Pull the image:

```bash
docker pull ghcr.io/coders-compass/caddy-with-ratelimit:latest
```

### With Docker Compose

Create a `docker-compose.yml`:

```yaml
services:
  caddy:
    image: ghcr.io/coders-compass/caddy-with-ratelimit:latest
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    restart: unless-stopped
```

### Example Caddyfile with Rate Limiting

Create a `Caddyfile`:

```caddyfile
{
    # Order directive is important for non-standard modules
    order rate_limit before basicauth
}

example.com {
    # Rate limit based on client IP
    rate_limit {
        zone dynamic_zone {
            key {http.request.remote.host}
            events 10
            window 1m
        }
    }

    # Your backend or static files
    reverse_proxy backend:8080
}
```

### Rate Limiting Configuration

The `rate_limit` directive supports various configurations:

**By IP address (most common)**:

```caddyfile
rate_limit {
    zone by_ip {
        key {http.request.remote.host}
        events 100
        window 1m
    }
}
```

**By header (e.g., API key)**:

```caddyfile
rate_limit {
    zone by_api_key {
        key {http.request.header.X-API-Key}
        events 1000
        window 1h
    }
}
```

**Static (global across all clients)**:

```caddyfile
rate_limit {
    zone global {
        key static
        events 10000
        window 1m
    }
}
```

**Multiple zones**:

```caddyfile
rate_limit {
    zone strict_endpoint {
        key {http.request.remote.host}
        events 5
        window 1m
    }
    zone general {
        key {http.request.remote.host}
        events 100
        window 1m
    }
}
```

### Distributed Rate Limiting

For multi-instance deployments sharing rate limit state:

```caddyfile
{
    order rate_limit before basicauth

    # Configure storage backend (e.g., Redis)
    storage redis {
        address "redis:6379"
    }
}

example.com {
    rate_limit {
        zone shared {
            key {http.request.remote.host}
            events 100
            window 1m
        }
        distributed {
            read_interval 100ms
            write_interval 100ms
        }
    }

    reverse_proxy backend:8080
}
```

## Rate Limit Response

When rate limit is exceeded:

- **HTTP Status**: `429 Too Many Requests`
- **Header**: `Retry-After` (seconds until rate limit resets)

## Image Details

- **Registry**: GitHub Container Registry (GHCR)
- **Image**: `ghcr.io/coders-compass/caddy-with-ratelimit:latest`
- **Base**: Official Caddy 2
- **Plugin**: github.com/mholt/caddy-ratelimit
- **Updates**: Automatically rebuilt weekly (Sundays)
- **Source**: [GitHub Repository](https://github.com/Coders-Compass/caddy-with-ratelimit)

## Available Tags

- `latest` - Latest build from main branch
- `main-<sha>` - Specific commit from main branch
- `YYYYMMDD` - Weekly scheduled builds

## Testing Rate Limiting

To verify rate limiting is working:

```bash
# Make rapid requests
for i in {1..15}; do
  curl -i http://localhost/
done
```

You should see `200 OK` for the first requests, then `429 Too Many Requests` once the limit is exceeded.

## Building Locally

```bash
git clone https://github.com/Coders-Compass/caddy-with-ratelimit.git
cd caddy-with-ratelimit
docker build -t caddy-with-ratelimit:local .
```

## Testing Locally

See the `test/` directory for a complete test setup with:

- Docker Compose stack
- Example Caddyfile with rate limiting
- Automated test script

```bash
cd test
docker compose up -d
./test.sh
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - See LICENSE file for details

## Maintainer

[@hungrybluedev](https://github.com/hungrybluedev)

## Acknowledgments

- [Caddy](https://caddyserver.com/) - The amazing web server
- [mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) - The rate limiting plugin
- Inspired by [debian-act-runner](https://github.com/Coders-Compass/debian-act-runner)

## Resources

- [Caddy Documentation](https://caddyserver.com/docs/)
- [Rate Limit Plugin Docs](https://github.com/mholt/caddy-ratelimit)
- [xcaddy - Custom Caddy Builder](https://github.com/caddyserver/xcaddy)
