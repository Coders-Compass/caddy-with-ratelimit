# Caddy with Rate Limiting

[![Test Rate Limiting](https://github.com/Coders-Compass/caddy-with-ratelimit/actions/workflows/test-rate-limiting.yml/badge.svg)](https://github.com/Coders-Compass/caddy-with-ratelimit/actions/workflows/test-rate-limiting.yml)
[![Build and Push](https://github.com/Coders-Compass/caddy-with-ratelimit/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/Coders-Compass/caddy-with-ratelimit/actions/workflows/build-and-push.yml)

A production-ready Caddy web server Docker image with the [mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) plugin pre-installed for HTTP rate limiting capabilities.

## Features

- **Base**: Official Caddy 2 image
- **Rate Limiting**: mholt/caddy-ratelimit plugin included
- **Multi-arch**: Supports both amd64 and arm64
- **Auto-updates**: Weekly automated builds on Sundays to get latest security patches
- **Production-ready**: Built with xcaddy using stable, tested versions
- **Quantified verification**: Every build runs 7 load-test scenarios with hard tolerance bands and cross-checks the plugin's own Prometheus counters against externally-observed behaviour (see [Verified behavior](#verified-behavior))

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

## Verified behavior

Every push, PR, and weekly rebuild runs an automated load-test suite against the built image and asserts the following with hard tolerance bands. Any deviation outside the bands fails CI.

| Scenario | What it verifies |
| --- | --- |
| Light load (under limit) | Under-limit traffic returns HTTP 200; no false positives. |
| Burst at limit | Exactly at the configured budget, every request succeeds. |
| Burst over limit | A 10-request burst against a 5/10s zone returns 4–6 × 200 + 4–6 × 429. |
| Sustained 30s @ 1 rps | Sustained over-limit traffic returns a mix of 200/429; sliding window enforces the average rate. |
| Multi-IP isolation | Three IPs (via trusted `X-Forwarded-For`) each receive their own budget; one IP exhausting its budget does not affect the others. |
| Multi-zone isolation | Two zones with different `events`/`window` move independently; exhausting one does not trip the other. |
| Long sustained 60s @ 1 rps | Over multiple windows, accepted RPS converges within tolerance of the configured `events/window` rate. |

**The single strongest assertion** across every scenario: the plugin's own `caddy_rate_limit_declined_requests_total` counter delta must match the externally-observed 429 count within ±1. This catches any regression where the limiter stops firing but a 429 is still returned (or vice versa) by something else in the request path.

Each CI run uploads:

- `summary.json` — machine-readable per-scenario JSON with timestamps, commit SHA, Caddy and plugin versions, status-code distribution, latency percentiles (p50–p99.99), RPS, and plugin counter deltas. Suitable for archival or aggregation.
- `summary.md` — human-readable Markdown, also rendered into the workflow Step Summary and posted as a sticky comment on PRs.

Artifacts live in the workflow run under "Artifacts" with 90-day retention.

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

The `test/` directory contains the same setup CI runs:

- Docker Compose stack with two rate-limit zones and a `/metrics` endpoint
- `test.sh` — quick functional smoke tests (curl-based)
- `load-test.sh` — the full 7-scenario load-test suite that emits `test/results/summary.json` + `summary.md` and exits non-zero on any band miss

Prerequisites: Docker, `curl`, `jq`, and [`oha`](https://github.com/hatoo/oha) on your PATH.

```bash
cd test
docker compose up -d
./test.sh           # functional smoke tests
./load-test.sh      # numeric verification + JSON/Markdown artefacts
```

Results land in `test/results/`. The script exits 0 only when every scenario falls inside its tolerance band, with a per-scenario fail reason explaining which band was missed.

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
