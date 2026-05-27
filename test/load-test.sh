#!/usr/bin/env bash
# Caddy rate-limit load test.
#
# Each scenario:
#   1. Waits for the rate-limit window to clear.
#   2. Snapshots the plugin's Prometheus declined-counter.
#   3. Runs traffic (oha for proper load, curl for single-IP scripted patterns).
#   4. Snapshots the counter again and computes the delta.
#   5. Asserts oha's externally-observed 200/429 counts and p99 latency are
#      inside per-scenario tolerance bands.
#   6. Cross-checks plugin-counter-delta against externally-observed 429 count
#      within ±1 — this is the strongest evidence that the limiter is actually
#      firing and not just an externally-mimicked status code.
#
# Output:
#   test/results/<id>.json    — raw oha JSON (per oha-driven scenario)
#   test/results/summary.json — machine-readable summary across all scenarios
#   test/results/summary.md   — human-readable Markdown table
#
# Exit code: 0 if every scenario passes, 1 if any scenario fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
TARGET_URL="${TARGET_URL:-http://localhost:8080}"
METRICS_URL="${METRICS_URL:-${TARGET_URL}/metrics}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Hard tolerances. Keep these conservative so transient timing variance in
# the sliding-window limiter does not flake the build, but tight enough that
# any real regression in limiter behaviour shows up.
# (BAND_S* are passed by name to oha_scenario and resolved via `declare -n`,
# which shellcheck cannot trace — hence the SC2034 disable below.)
# shellcheck disable=SC2034
#                          200_min  200_max  429_min  429_max  p99_ms_max
declare -A BAND_S1=([min200]=3  [max200]=3  [min429]=0   [max429]=0   [p99_ms]=500)
declare -A BAND_S2=([min200]=5  [max200]=5  [min429]=0   [max429]=0   [p99_ms]=500)
declare -A BAND_S3=([min200]=4  [max200]=6  [min429]=4   [max429]=6   [p99_ms]=500)
# s4 — 1 rps for 30s = 30 req. Initial 5 accepted + sliding window ~0.5 rps after → ~17 accepted, ~13 declined.
declare -A BAND_S4=([min200]=10 [max200]=22 [min429]=5   [max429]=999 [p99_ms]=500)
declare -A BAND_S5=([min200]=12 [max200]=12 [min429]=0   [max429]=0   [p99_ms]=500)
declare -A BAND_S6_T=([min200]=5 [max200]=5  [min429]=3   [max429]=3   [p99_ms]=500)
declare -A BAND_S6_B=([min200]=3 [max200]=3  [min429]=0   [max429]=0   [p99_ms]=500)
# s7 — 1 rps for 60s = 60 req. Initial 5 + sliding window ~0.5 rps × 55s → ~32 accepted.
declare -A BAND_S7=([min200]=22 [max200]=42 [min429]=15  [max429]=999 [p99_ms]=500)

# Used 12s for the 10s window scenarios, longer for sustained ones run more
# recently against the same zone.
RESET_DEFAULT=12

mkdir -p "$RESULTS_DIR"
SCENARIOS_JSON='[]'
PASS_COUNT=0
FAIL_COUNT=0

# ---------- helpers ---------------------------------------------------------

require() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}✗ '$1' is required but not installed${NC}" >&2
    exit 1
  fi
}

get_declined_aggregate() {
  # Aggregate counter for a zone (sum across keys, exposed by the plugin with
  # the empty-string key label). Returns "0" if the counter has not yet been
  # incremented — Prometheus only creates label series on first increment.
  local zone="$1"
  local pattern="caddy_rate_limit_declined_requests_total{key=\"\",zone=\"$zone\"}"
  local body line
  body=$(curl -fsS "$METRICS_URL" 2>/dev/null || echo "")
  line=$(printf '%s\n' "$body" | grep -F "$pattern" || true)
  if [[ -z "$line" ]]; then echo "0"; else echo "$line" | awk '{print $NF; exit}'; fi
}

get_declined_for_key() {
  local zone="$1"; local key="$2"
  local pattern="caddy_rate_limit_declined_requests_total{key=\"$key\",zone=\"$zone\"}"
  local body line
  body=$(curl -fsS "$METRICS_URL" 2>/dev/null || echo "")
  line=$(printf '%s\n' "$body" | grep -F "$pattern" || true)
  if [[ -z "$line" ]]; then echo "0"; else echo "$line" | awk '{print $NF; exit}'; fi
}

in_band() {
  # usage: in_band <value> <min> <max>
  local v="$1" lo="$2" hi="$3"
  [[ "$v" -ge "$lo" && "$v" -le "$hi" ]]
}

# Convert a bash array of strings into a JSON array string; emits "[]" when
# the array is empty (avoids the [""] surprise from `printf '%s\n' ""`).
arr_to_json() {
  if (( $# == 0 )); then echo '[]'; return; fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

# Append a scenario result object to the SCENARIOS_JSON array.
record_scenario() {
  local frag="$1"
  SCENARIOS_JSON=$(echo "$SCENARIOS_JSON" | jq --argjson new "$frag" '. + [$new]')
}

# Run one oha-driven scenario.
# usage: oha_scenario <id> <title> <zone> <expected-band-array-name> <oha args>
oha_scenario() {
  local id="$1"; local title="$2"; local zone="$3"; local band_name="$4"; shift 4
  local oha_args=("$@")
  local -n band="$band_name"

  echo ""
  echo -e "${BLUE}── $id: $title ──${NC}"
  echo "    zone=$zone  expected 200 in [${band[min200]}, ${band[max200]}], 429 in [${band[min429]}, ${band[max429]}]"
  sleep "$RESET_DEFAULT"

  local before; before=$(get_declined_aggregate "$zone")
  local out="${RESULTS_DIR}/${id}.json"
  oha --json --no-tui "${oha_args[@]}" "$TARGET_URL/" > "$out"
  local after; after=$(get_declined_aggregate "$zone")
  local plugin_delta=$((after - before))

  local ok200 oha429 p99_ms rps
  ok200=$(jq -r '.statusCodeDistribution["200"] // 0' "$out")
  oha429=$(jq -r '.statusCodeDistribution["429"] // 0' "$out")
  p99_ms=$(jq -r '((.latencyPercentiles.p99 // 0) * 1000) | floor' "$out")
  rps=$(jq -r '.summary.requestsPerSec // 0' "$out")

  local fail_reasons=()
  in_band "$ok200" "${band[min200]}" "${band[max200]}" \
    || fail_reasons+=("200 count=$ok200 outside [${band[min200]}, ${band[max200]}]")
  in_band "$oha429" "${band[min429]}" "${band[max429]}" \
    || fail_reasons+=("429 count=$oha429 outside [${band[min429]}, ${band[max429]}]")
  [[ "$p99_ms" -le "${band[p99_ms]}" ]] \
    || fail_reasons+=("p99=${p99_ms}ms exceeds ${band[p99_ms]}ms")
  local diff=$((plugin_delta - oha429))
  if [[ "$diff" -lt -1 || "$diff" -gt 1 ]]; then
    fail_reasons+=("plugin-counter delta=$plugin_delta vs oha 429=$oha429 differ by $diff (allowed ±1)")
  fi

  local status="pass"
  if [[ ${#fail_reasons[@]} -gt 0 ]]; then
    status="fail"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}    ✗ FAIL${NC}"
    for r in "${fail_reasons[@]}"; do echo -e "${RED}      - $r${NC}"; done
  else
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}    ✓ pass: 200=$ok200  429=$oha429  plugin-delta=$plugin_delta  p99=${p99_ms}ms  rps=$(printf '%.1f' "$rps")${NC}"
  fi

  record_scenario "$(jq -n \
    --arg id "$id" --arg title "$title" --arg zone "$zone" --arg status "$status" \
    --argjson http_200 "$ok200" --argjson http_429 "$oha429" \
    --argjson plugin_declined_delta "$plugin_delta" \
    --argjson p99_ms "$p99_ms" --argjson rps "$rps" \
    --argjson band_min200 "${band[min200]}" --argjson band_max200 "${band[max200]}" \
    --argjson band_min429 "${band[min429]}" --argjson band_max429 "${band[max429]}" \
    --argjson band_p99_ms "${band[p99_ms]}" \
    --argjson fail_reasons "$(arr_to_json "${fail_reasons[@]+"${fail_reasons[@]}"}")" \
    '{
      id: $id, title: $title, zone: $zone, status: $status,
      observed: {http_200: $http_200, http_429: $http_429, plugin_declined_delta: $plugin_declined_delta, p99_ms: $p99_ms, rps: $rps},
      expected: {http_200_band: [$band_min200, $band_max200], http_429_band: [$band_min429, $band_max429], p99_ms_max: $band_p99_ms},
      fail_reasons: $fail_reasons
    }')"
}

# ---------- prerequisites ---------------------------------------------------

require oha
require curl
require jq

if ! docker compose ps 2>/dev/null | grep -q "caddy.*Up"; then
  echo -e "${RED}✗ Caddy stack is not running. Run 'docker compose up -d' from the test/ directory first.${NC}" >&2
  exit 1
fi

echo -e "${YELLOW}Waiting for Caddy and /metrics to be ready...${NC}"
attempt=0
while ! curl -fsS "$METRICS_URL" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [[ $attempt -ge 30 ]]; then
    echo -e "${RED}✗ /metrics never came up at $METRICS_URL${NC}" >&2
    exit 1
  fi
  sleep 1
done
echo -e "${GREEN}✓ Caddy ready, /metrics reachable${NC}"

# ---------- metadata --------------------------------------------------------

CADDY_VERSION=$(docker compose exec -T caddy caddy version 2>/dev/null | head -n1 || echo "unknown")
PLUGIN_SHA=$(grep -oP 'github\.com/mholt/caddy-ratelimit@\K[a-f0-9]{40}' "$SCRIPT_DIR/../Dockerfile" || echo "unknown")
OHA_VERSION=$(oha --version 2>/dev/null | head -n1 || echo "unknown")
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)}"

# ---------- scenarios -------------------------------------------------------

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE} Caddy Rate Limit — Load Test & Verification${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo "  Caddy:     $CADDY_VERSION"
echo "  Plugin:    $PLUGIN_SHA"
echo "  oha:       $OHA_VERSION"
echo "  target:    $TARGET_URL"
echo "  metrics:   $METRICS_URL"

oha_scenario s1_light "Light load (3 req, under limit)" test_zone BAND_S1 \
  -n 3

oha_scenario s2_at_limit "Burst at limit (5 req as fast as possible)" test_zone BAND_S2 \
  -n 5

oha_scenario s3_over_limit "Burst over limit (10 req as fast as possible)" test_zone BAND_S3 \
  -n 10

oha_scenario s4_sustained "Sustained load (30s @ 1 rps)" test_zone BAND_S4 \
  -z 30s -q 1

# s5 — Multi-IP isolation. 3 fake IPs × 4 requests each = 12 requests; all
# should succeed (4 < limit of 5 per key). We use curl rather than oha because
# oha sends one X-Forwarded-For per run.
echo ""
echo -e "${BLUE}── s5_multi_ip: Multi-IP isolation (3 IPs × 4 req, under per-IP limit) ──${NC}"
sleep "$RESET_DEFAULT"
S5_IPS=("10.0.0.51" "10.0.0.52" "10.0.0.53")
declare -A S5_BEFORE
for ip in "${S5_IPS[@]}"; do S5_BEFORE[$ip]=$(get_declined_for_key test_zone "$ip"); done
s5_200=0; s5_429=0
for ip in "${S5_IPS[@]}"; do
  for _ in 1 2 3 4; do
    code=$(curl -s -H "X-Forwarded-For: $ip" -o /dev/null -w "%{http_code}" "$TARGET_URL/")
    case "$code" in
      200) s5_200=$((s5_200 + 1)) ;;
      429) s5_429=$((s5_429 + 1)) ;;
    esac
  done
done
s5_plugin_delta=0
for ip in "${S5_IPS[@]}"; do
  s5_after=$(get_declined_for_key test_zone "$ip")
  d=$((s5_after - ${S5_BEFORE[$ip]}))
  s5_plugin_delta=$((s5_plugin_delta + d))
done
s5_fail=()
in_band "$s5_200" "${BAND_S5[min200]}" "${BAND_S5[max200]}" \
  || s5_fail+=("200 count=$s5_200 outside [${BAND_S5[min200]}, ${BAND_S5[max200]}]")
in_band "$s5_429" "${BAND_S5[min429]}" "${BAND_S5[max429]}" \
  || s5_fail+=("429 count=$s5_429 outside [${BAND_S5[min429]}, ${BAND_S5[max429]}]")
diff=$((s5_plugin_delta - s5_429))
if [[ "$diff" -lt -1 || "$diff" -gt 1 ]]; then
  s5_fail+=("plugin-counter delta=$s5_plugin_delta vs observed 429=$s5_429 differ by $diff")
fi
s5_status="pass"; [[ ${#s5_fail[@]} -gt 0 ]] && s5_status="fail"
if [[ "$s5_status" = "fail" ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "${RED}    ✗ FAIL${NC}"
  for r in "${s5_fail[@]}"; do echo -e "${RED}      - $r${NC}"; done
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "${GREEN}    ✓ pass: 200=$s5_200  429=$s5_429  plugin-delta=$s5_plugin_delta${NC}"
fi
record_scenario "$(jq -n \
  --arg id "s5_multi_ip" --arg title "Multi-IP isolation (3 IPs × 4 req)" \
  --arg zone "test_zone" --arg status "$s5_status" \
  --argjson http_200 "$s5_200" --argjson http_429 "$s5_429" \
  --argjson plugin_declined_delta "$s5_plugin_delta" \
  --argjson p99_ms 0 --argjson rps 0 \
  --argjson band_min200 "${BAND_S5[min200]}" --argjson band_max200 "${BAND_S5[max200]}" \
  --argjson band_min429 "${BAND_S5[min429]}" --argjson band_max429 "${BAND_S5[max429]}" \
  --argjson band_p99_ms "${BAND_S5[p99_ms]}" \
  --argjson fail_reasons "$(arr_to_json "${s5_fail[@]+"${s5_fail[@]}"}")" \
  '{id: $id, title: $title, zone: $zone, status: $status,
    observed: {http_200: $http_200, http_429: $http_429, plugin_declined_delta: $plugin_declined_delta, p99_ms: $p99_ms, rps: $rps},
    expected: {http_200_band: [$band_min200, $band_max200], http_429_band: [$band_min429, $band_max429], p99_ms_max: $band_p99_ms},
    fail_reasons: $fail_reasons}')"

# s6 — Multi-zone isolation. Exhaust test_zone (8 req on /) and prove
# burst_zone (3 req on /burst) is unaffected.
echo ""
echo -e "${BLUE}── s6_multi_zone: Multi-zone isolation (exhaust test_zone, hit burst_zone) ──${NC}"
sleep "$RESET_DEFAULT"
s6_before_t=$(get_declined_aggregate test_zone)
s6_before_b=$(get_declined_aggregate burst_zone)
# 8 req on test_zone → 5 × 200, 3 × 429 expected
s6_t_200=0; s6_t_429=0
for _ in 1 2 3 4 5 6 7 8; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/")
  [[ "$code" = "200" ]] && s6_t_200=$((s6_t_200 + 1))
  [[ "$code" = "429" ]] && s6_t_429=$((s6_t_429 + 1))
done
# 3 req on burst_zone → all 200 expected
s6_b_200=0; s6_b_429=0
for _ in 1 2 3; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/burst/x")
  [[ "$code" = "200" ]] && s6_b_200=$((s6_b_200 + 1))
  [[ "$code" = "429" ]] && s6_b_429=$((s6_b_429 + 1))
done
s6_after_t=$(get_declined_aggregate test_zone)
s6_after_b=$(get_declined_aggregate burst_zone)
s6_delta_t=$((s6_after_t - s6_before_t))
s6_delta_b=$((s6_after_b - s6_before_b))
s6_fail=()
in_band "$s6_t_200" "${BAND_S6_T[min200]}" "${BAND_S6_T[max200]}" \
  || s6_fail+=("test_zone 200=$s6_t_200 outside [${BAND_S6_T[min200]}, ${BAND_S6_T[max200]}]")
in_band "$s6_t_429" "${BAND_S6_T[min429]}" "${BAND_S6_T[max429]}" \
  || s6_fail+=("test_zone 429=$s6_t_429 outside [${BAND_S6_T[min429]}, ${BAND_S6_T[max429]}]")
in_band "$s6_b_200" "${BAND_S6_B[min200]}" "${BAND_S6_B[max200]}" \
  || s6_fail+=("burst_zone 200=$s6_b_200 outside [${BAND_S6_B[min200]}, ${BAND_S6_B[max200]}]")
in_band "$s6_b_429" "${BAND_S6_B[min429]}" "${BAND_S6_B[max429]}" \
  || s6_fail+=("burst_zone 429=$s6_b_429 outside [${BAND_S6_B[min429]}, ${BAND_S6_B[max429]}]")
diff_t=$((s6_delta_t - s6_t_429))
diff_b=$((s6_delta_b - s6_b_429))
if [[ "$diff_t" -lt -1 || "$diff_t" -gt 1 ]]; then
  s6_fail+=("test_zone plugin-delta=$s6_delta_t vs observed=$s6_t_429 differ by $diff_t")
fi
if [[ "$diff_b" -lt -1 || "$diff_b" -gt 1 ]]; then
  s6_fail+=("burst_zone plugin-delta=$s6_delta_b vs observed=$s6_b_429 differ by $diff_b")
fi
s6_status="pass"; [[ ${#s6_fail[@]} -gt 0 ]] && s6_status="fail"
if [[ "$s6_status" = "fail" ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "${RED}    ✗ FAIL${NC}"
  for r in "${s6_fail[@]}"; do echo -e "${RED}      - $r${NC}"; done
else
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "${GREEN}    ✓ pass: test_zone 200=$s6_t_200/429=$s6_t_429 (Δ=$s6_delta_t)  burst_zone 200=$s6_b_200/429=$s6_b_429 (Δ=$s6_delta_b)${NC}"
fi
record_scenario "$(jq -n \
  --arg id "s6_multi_zone" --arg title "Multi-zone isolation" --arg status "$s6_status" \
  --argjson tz_200 "$s6_t_200" --argjson tz_429 "$s6_t_429" --argjson tz_plugin "$s6_delta_t" \
  --argjson bz_200 "$s6_b_200" --argjson bz_429 "$s6_b_429" --argjson bz_plugin "$s6_delta_b" \
  --argjson fail_reasons "$(arr_to_json "${s6_fail[@]+"${s6_fail[@]}"}")" \
  '{id: $id, title: $title, status: $status,
    observed: {
      test_zone: {http_200: $tz_200, http_429: $tz_429, plugin_declined_delta: $tz_plugin},
      burst_zone: {http_200: $bz_200, http_429: $bz_429, plugin_declined_delta: $bz_plugin}},
    fail_reasons: $fail_reasons}')"

# s7 — Long sustained: 60s at 1 rps. Sliding window should hold accepted RPS
# near the configured 0.5 rps (5 events / 10s) regardless of duration.
oha_scenario s7_long_sustained "Long sustained (60s @ 1 rps, sliding-window convergence)" test_zone BAND_S7 \
  -z 60s -q 1

# ---------- summary ---------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))
VERDICT="pass"; [[ "$FAIL_COUNT" -gt 0 ]] && VERDICT="fail"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUNNER_OS="${RUNNER_OS:-$(uname -s)}"
RUNNER_ARCH="${RUNNER_ARCH:-$(uname -m)}"

echo "$SCENARIOS_JSON" | jq \
  --arg ts "$TS" --arg commit "$COMMIT_SHA" --arg caddy "$CADDY_VERSION" \
  --arg plugin "$PLUGIN_SHA" --arg oha "$OHA_VERSION" \
  --arg os "$RUNNER_OS" --arg arch "$RUNNER_ARCH" \
  --argjson pass "$PASS_COUNT" --argjson fail "$FAIL_COUNT" --argjson total "$TOTAL" \
  --arg verdict "$VERDICT" \
  '{
    metadata: {timestamp: $ts, commit_sha: $commit, caddy_version: $caddy, plugin_sha: $plugin, oha_version: $oha, runner_os: $os, runner_arch: $arch},
    verdict: $verdict,
    counts: {passed: $pass, failed: $fail, total: $total},
    scenarios: .
  }' > "$RESULTS_DIR/summary.json"

{
  # HTML-comment marker — CI uses this to find the sticky PR comment to update.
  echo "<!-- rate-limit-results -->"
  echo "# Caddy Rate-Limit Verification — $TS"
  echo ""
  echo "**Verdict:** $([ "$VERDICT" = "pass" ] && echo "✅ PASS" || echo "❌ FAIL") ($PASS_COUNT/$TOTAL scenarios)"
  echo ""
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Commit | \`$COMMIT_SHA\` |"
  echo "| Caddy | $CADDY_VERSION |"
  echo "| Plugin SHA | \`$PLUGIN_SHA\` |"
  echo "| oha | $OHA_VERSION |"
  echo "| Runner | $RUNNER_OS $RUNNER_ARCH |"
  echo ""
  echo "## Scenarios"
  echo ""
  echo "| ID | Scenario | Status | 200 (expected) | 429 (expected) | Plugin Δ | p99 (ms) |"
  echo "| --- | --- | --- | --- | --- | --- | --- |"
  jq -r '.scenarios[] |
    if .observed.test_zone then
      "| \(.id) | \(.title) | \(if .status=="pass" then "✅" else "❌" end) | test_zone:\(.observed.test_zone.http_200)/burst_zone:\(.observed.burst_zone.http_200) | test_zone:\(.observed.test_zone.http_429)/burst_zone:\(.observed.burst_zone.http_429) | tz:\(.observed.test_zone.plugin_declined_delta)/bz:\(.observed.burst_zone.plugin_declined_delta) | n/a |"
    else
      "| \(.id) | \(.title) | \(if .status=="pass" then "✅" else "❌" end) | \(.observed.http_200) (\(.expected.http_200_band[0])–\(.expected.http_200_band[1])) | \(.observed.http_429) (\(.expected.http_429_band[0])–\(.expected.http_429_band[1])) | \(.observed.plugin_declined_delta) | \(.observed.p99_ms) |"
    end' "$RESULTS_DIR/summary.json"
  echo ""
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "## Failures"
    echo ""
    jq -r '.scenarios[] | select(.status=="fail") |
      "- **\(.id)** — \(.title)\n  - " + (.fail_reasons | join("\n  - "))' "$RESULTS_DIR/summary.json"
    echo ""
  fi
  echo "_Cross-check rule: plugin-reported declined counter delta must match externally-observed HTTP 429 count within ±1._"
} > "$RESULTS_DIR/summary.md"

echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
if [[ "$VERDICT" = "pass" ]]; then
  echo -e "${GREEN} ✅ All $TOTAL scenarios passed${NC}"
else
  echo -e "${RED} ❌ $FAIL_COUNT of $TOTAL scenarios failed${NC}"
fi
echo -e "${BLUE} Results: $RESULTS_DIR/summary.json, summary.md${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"

[[ "$VERDICT" = "pass" ]]
