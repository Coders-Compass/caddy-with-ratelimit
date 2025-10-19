#!/usr/bin/env bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TARGET_URL="http://localhost:8080"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Caddy Rate Limiting - Load Test${NC}"
echo -e "${BLUE}Using 'oha' load testing tool${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if oha is installed
if ! command -v oha &> /dev/null; then
    echo -e "${RED}✗ 'oha' is not installed${NC}"
    echo ""
    echo "Install oha:"
    echo "  macOS:  brew install oha"
    echo "  Linux:  cargo install oha"
    echo "  Or download from: https://github.com/hatoo/oha/releases"
    exit 1
fi

echo -e "${GREEN}✓ 'oha' is installed ($(oha --version))${NC}"
echo ""

# Check if services are running
echo -e "${YELLOW}Checking if Caddy is running...${NC}"
if ! docker compose ps | grep -q "caddy.*Up"; then
    echo -e "${RED}✗ Caddy is not running. Start it with: docker compose up -d${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Caddy is running${NC}"
echo ""

# Wait for Caddy to be ready
echo -e "${YELLOW}Waiting for Caddy to be ready...${NC}"
max_attempts=30
attempt=0
while ! curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL" | grep -q "200"; do
    attempt=$((attempt + 1))
    if [ $attempt -ge $max_attempts ]; then
        echo -e "${RED}✗ Caddy did not become ready in time${NC}"
        exit 1
    fi
    sleep 1
done
echo -e "${GREEN}✓ Caddy is ready${NC}"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test 1: Light Load (Under Limit)${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Sending 3 requests total with 2s between requests"
echo "Rate limit: 5 requests per 10s"
echo "Expected: All requests succeed (200)"
echo ""

oha -n 3 -q 0.5 --no-tui "$TARGET_URL"

echo ""
echo -e "${YELLOW}Waiting 12 seconds for rate limit window to reset...${NC}"
sleep 12
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test 2: Burst at Limit${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Sending 5 requests as fast as possible"
echo "Rate limit: 5 requests per 10s"
echo "Expected: Most/all succeed (at the boundary)"
echo ""

oha -n 5 --no-tui "$TARGET_URL"

echo ""
echo -e "${YELLOW}Waiting 12 seconds for rate limit window to reset...${NC}"
sleep 12
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test 3: Burst Over Limit${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Sending 10 requests as fast as possible"
echo "Expected: ~5 succeed (200), ~5 rate-limited (429)"
echo ""

oha -n 10 --no-tui "$TARGET_URL"

echo ""
echo -e "${YELLOW}Waiting 12 seconds for rate limit window to reset...${NC}"
sleep 12
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test 4: Sustained Load${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Sending 20 requests over 30 seconds (~0.67 req/s)"
echo "Rate limit: 5 requests per 10s = 0.5 req/s"
echo "Expected: Mix of 200 and 429 responses"
echo ""

oha -z 30s -q 0.67 --no-tui "$TARGET_URL"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Load tests complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Key Findings:${NC}"
echo "• Test 1: Light load should have 100% success (all 200)"
echo "• Test 2: Burst at limit may have some 429s due to timing"
echo "• Test 3: Clear evidence of rate limiting (mix of 200/429)"
echo "• Test 4: Sustained load shows rate limiting over time"
echo ""
echo -e "${YELLOW}Rate Limiting Observations:${NC}"
echo "• 429 responses indicate rate limiting is active"
echo "• Higher 429 rate = more aggressive limiting"
echo "• Check 'Status code distribution' in results above"
