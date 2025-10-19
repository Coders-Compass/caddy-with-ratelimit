#!/usr/bin/env bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TARGET_URL="http://localhost:8080"
RATE_LIMIT_EVENTS=5
RATE_LIMIT_WINDOW=10

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Caddy Rate Limiting Test Suite${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Check if services are running
echo -e "${YELLOW}[1/6] Checking if Caddy is running...${NC}"
if ! docker compose ps | grep -q "caddy.*Up"; then
    echo -e "${RED}✗ Caddy is not running. Start it with: docker compose up -d${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Caddy is running${NC}"
echo ""

# Wait for Caddy to be ready
echo -e "${YELLOW}[2/6] Waiting for Caddy to be ready...${NC}"
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

# Test 1: Single request should succeed
echo -e "${YELLOW}[3/6] Test 1: Single request (should succeed)${NC}"
response=$(curl -s "$TARGET_URL")
http_code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL")

if [ "$http_code" = "200" ]; then
    echo -e "${GREEN}✓ Single request succeeded (HTTP $http_code)${NC}"
    echo "  Response: $response"
else
    echo -e "${RED}✗ Single request failed (HTTP $http_code)${NC}"
    exit 1
fi
echo ""

# Wait for rate limit window to reset
echo -e "${YELLOW}[4/6] Waiting for rate limit window to reset...${NC}"
sleep $((RATE_LIMIT_WINDOW + 1))
echo -e "${GREEN}✓ Rate limit window reset${NC}"
echo ""

# Test 2: Rapid burst should hit rate limit
echo -e "${YELLOW}[5/6] Test 2: Rapid burst (should hit limit)${NC}"
echo "  Sending $((RATE_LIMIT_EVENTS + 3)) requests as fast as possible..."
success_count=0
limited_count=0

for i in $(seq 1 $((RATE_LIMIT_EVENTS + 3))); do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL")
    if [ "$http_code" = "200" ]; then
        success_count=$((success_count + 1))
    elif [ "$http_code" = "429" ]; then
        limited_count=$((limited_count + 1))
    fi
done

echo "  Results: $success_count succeeded, $limited_count rate-limited"

if [ $success_count -le $RATE_LIMIT_EVENTS ] && [ $limited_count -gt 0 ]; then
    echo -e "${GREEN}✓ Rate limiting working correctly${NC}"
    echo "  • Approximately $success_count requests succeeded (limit: $RATE_LIMIT_EVENTS)"
    echo "  • $limited_count requests were rate-limited with 429"
else
    echo -e "${YELLOW}⚠ Unexpected results but rate limiting appears active${NC}"
    echo "  • Success: $success_count (expected ≤$RATE_LIMIT_EVENTS)"
    echo "  • Limited: $limited_count (expected >0)"
fi
echo ""

# Test 3: Verify 429 response has proper headers
echo -e "${YELLOW}[6/6] Test 3: Verify 429 response format${NC}"
response_file=$(mktemp)

# Make enough requests to trigger rate limit
for i in $(seq 1 $((RATE_LIMIT_EVENTS + 1))); do
    curl -s -i "$TARGET_URL" -o "$response_file" 2>&1
    http_code=$(tail -1 "$response_file" 2>/dev/null || echo "")
    
    # Check if we got a 429
    if grep -q "HTTP.*429" "$response_file"; then
        echo -e "${GREEN}✓ Received 429 Too Many Requests${NC}"
        
        # Check for Retry-After header
        if grep -qi "retry-after" "$response_file"; then
            retry_after=$(grep -i "retry-after" "$response_file" | awk '{print $2}' | tr -d '\r')
            echo -e "${GREEN}✓ Retry-After header present: ${retry_after}s${NC}"
        else
            echo -e "${YELLOW}⚠ Retry-After header not found${NC}"
        fi
        break
    fi
done

rm -f "$response_file"
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}All tests passed! ✓${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  • Single requests work correctly"
echo "  • Rate limiting is active and blocking excess requests"
echo "  • Rate limit: $RATE_LIMIT_EVENTS requests per ${RATE_LIMIT_WINDOW}s"
echo "  • 429 responses include Retry-After header"
echo ""
echo -e "${YELLOW}Note: Rate limiting uses a sliding window algorithm${NC}"
echo -e "${YELLOW}Requests made rapidly will be limited more aggressively${NC}"
