# Test Suite for Caddy with Rate Limiting

This directory contains test scripts to verify rate limiting functionality.

## Prerequisites

- Docker and Docker Compose
- `curl` (for basic tests)
- `oha` (for load tests) - Install via:
  - macOS: `brew install oha`
  - Linux/Others: `cargo install oha`
  - Or download from: https://github.com/hatoo/oha/releases

## Quick Start

1. **Start the test environment**:
   ```bash
   docker compose up -d
   ```

2. **Run basic tests**:
   ```bash
   chmod +x test.sh
   ./test.sh
   ```

3. **Run load tests** (requires `oha`):
   ```bash
   chmod +x load-test.sh
   ./load-test.sh
   ```

4. **Stop the environment**:
   ```bash
   docker compose down
   ```

## Test Scripts

### `test.sh` - Basic Functional Tests

Simple curl-based tests with 6 test phases:
1. **Check Caddy is running**: Verifies container is up
2. **Wait for readiness**: Ensures Caddy is accepting requests
3. **Single request test**: Validates basic functionality (expects 200)
4. **Rate limit window reset**: Waits 11 seconds to clear previous requests
5. **Rapid burst test**: Sends 8 requests quickly (expects ~5 success, ~3 rate-limited)
6. **429 response validation**: Confirms rate limit response has Retry-After header

**What it verifies:**
- Basic request/response works
- Rate limiting triggers after limit exceeded
- HTTP 429 responses are returned
- Retry-After header is present
- Sliding window algorithm is active

**Usage**:
```bash
./test.sh
```

### `load-test.sh` - Load Testing

Uses `oha` to perform realistic load tests with 4 test scenarios:
1. **Light Load**: 3 requests at 0.5 req/s (well under limit, expects 100% success)
2. **Burst at Limit**: 5 requests as fast as possible (at boundary, expects most succeed)
3. **Burst Over Limit**: 10 requests as fast as possible (expects ~50% rate-limited)
4. **Sustained Load**: 20 requests over 30s at 0.67 req/s (expects mix of 200/429)

Between each test, waits 12 seconds for rate limit window to reset.

**What it demonstrates:**
- Behavior under different load patterns
- Rate limiting accuracy with burst traffic
- Sustained load handling over time
- Performance characteristics

**Usage**:
```bash
./load-test.sh
```

## Configuration

### Rate Limit Settings

Edit `Caddyfile` to adjust rate limiting:

```caddyfile
rate_limit {
    zone test_zone {
        key {http.request.remote.host}
        events 5      # Max requests
        window 10s    # Time window
    }
}
```

### Testing Different Scenarios

**Stricter limits** (1 request per 5 seconds):
```caddyfile
zone strict {
    key {http.request.remote.host}
    events 1
    window 5s
}
```

**More permissive** (100 requests per minute):
```caddyfile
zone permissive {
    key {http.request.remote.host}
    events 100
    window 1m
}
```

## Manual Testing

### Single Request
```bash
curl http://localhost:8080
```

### Rapid Requests (trigger rate limit)
```bash
for i in {1..10}; do 
  curl -i http://localhost:8080
  echo "---"
done
```

### View Response Headers
```bash
curl -v http://localhost:8080
```

## Troubleshooting

### Caddy logs
```bash
docker compose logs -f caddy
```

### Rebuild image
```bash
docker compose build --no-cache
docker compose up -d
```

### Verify rate_limit module is loaded
```bash
docker compose exec caddy caddy list-modules | grep rate_limit
```

Expected output:
```
http.handlers.rate_limit
```

## Expected Test Results

### Basic Tests (`test.sh`)
- ✓ Test 1: Single request succeeds (HTTP 200)
- ✓ Test 2: Rapid burst of 8 requests results in ~5 success, ~3 rate-limited
- ✓ Test 3: 429 response includes Retry-After header
- All tests pass indicator at the end

### Load Tests (`load-test.sh`)

**Test 1 - Light Load** (3 req at 0.5 req/s):
- Success rate: 100%
- All responses: HTTP 200
- No rate limiting triggered

**Test 2 - Burst at Limit** (5 req immediately):
- Success rate: 100%
- All 5 requests: HTTP 200
- At the edge of the limit

**Test 3 - Burst Over Limit** (10 req immediately):
- Success rate: ~50%
- Status distribution: 5x HTTP 200, 5x HTTP 429
- Clear rate limiting demonstration

**Test 4 - Sustained Load** (20 req over 30s):
- Success rate: ~70-80%
- Status distribution: Mix of 200 and 429
- Shows rate limiting over time

## Notes

- Rate limit windows are based on time, so wait 10+ seconds between test runs
- The `key {http.request.remote.host}` means rate limiting is per-IP
- All requests from Docker containers appear to come from the same IP (Docker bridge)
- For production, consider using real client IPs with proper proxy headers
