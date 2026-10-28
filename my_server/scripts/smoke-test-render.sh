#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-}"
if [[ -z "$base_url" ]]; then
  echo "Usage: SMOKE_TEST_EMAIL=you@example.edu $0 https://your-server.example" >&2
  exit 2
fi
if [[ -z "${SMOKE_TEST_EMAIL:-}" ]]; then
  echo "Set SMOKE_TEST_EMAIL to an account email; it will not be printed." >&2
  exit 2
fi

base_url="${base_url%/}"
check() {
  local label="$1" expected="$2" method="$3" path="$4" payload="${5:-}"
  local status
  if [[ "$method" == "POST" ]]; then
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --request POST --header 'content-type: application/json' --data "$payload" "$base_url$path")"
  else
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$base_url$path")"
  fi
  if [[ "$status" == "$expected" ]]; then
    printf 'PASS %-34s HTTP %s\n' "$label" "$status"
  else
    printf 'FAIL %-34s expected HTTP %s, got %s\n' "$label" "$expected" "$status"
    return 1
  fi
}

check 'GET /' 200 GET /
check 'GET /api/health' 200 GET /api/health
check 'GET /api/me without token' 401 GET /api/me
payload="$(node -e 'process.stdout.write(JSON.stringify({email:process.env.SMOKE_TEST_EMAIL,password:"SmokeOnly-Invalid-9c48f4a7e2d1"}))')"
check 'POST /api/auth/login wrong password' 401 POST /api/auth/login "$payload"
