#!/usr/bin/env bash
set -euo pipefail

: "${BASE_URL:?Set BASE_URL to the API service origin}"
: "${TEST_EMAIL:?Set TEST_EMAIL to a test account email}"

api_base=${BASE_URL%/}

json_payload() {
  printf '%s\n%s\n%s\n' "$1" "$2" "$3" | node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (part) => input += part);
    process.stdin.on("end", () => {
      const [email, otp, newPassword] = input.split("\n");
      const payload = otp === "" && newPassword === ""
        ? { method: "email", email }
        : { email, otp, newPassword };
      process.stdout.write(JSON.stringify(payload));
    });
  '
}

post_json() {
  local endpoint="$1"
  local body="$2"
  printf '%s' "$body" | curl --silent --show-error --max-time 80 \
    --write-out $'\n%{http_code}' \
    --request POST "$api_base/api/auth/$endpoint" \
    --header 'Content-Type: application/json' \
    --data-binary @-
}

print_response() {
  local response="$1"
  local status="${response##*$'\n'}"
  local body="${response%$'\n'*}"
  printf 'HTTP status: %s\n%s\n' "$status" "$body"
}

printf 'Requesting password recovery...\n'
request_body=$(json_payload "$TEST_EMAIL" '' '')
request_response=$(post_json 'forgot-password' "$request_body")
print_response "$request_response"

read -r -s -p 'Enter the recovery code: ' otp
printf '\n'
read -r -s -p 'Enter the new password: ' new_password
printf '\n'

if [[ ! "$otp" =~ ^[0-9]{6}$ ]]; then
  printf 'The recovery code must contain six digits.\n' >&2
  exit 2
fi

if [[ "${otp:0:1}" == '0' ]]; then
  wrong_otp="1${otp:1}"
else
  wrong_otp="0${otp:1}"
fi

printf 'Checking rejection of a wrong code...\n'
wrong_body=$(json_payload "$TEST_EMAIL" "$wrong_otp" "$new_password")
wrong_response=$(post_json 'password-recovery/verify' "$wrong_body")
print_response "$wrong_response"
unset wrong_otp wrong_body wrong_response

printf 'Verifying the recovery code...\n'
verify_body=$(json_payload "$TEST_EMAIL" "$otp" "$new_password")
verify_response=$(post_json 'password-recovery/verify' "$verify_body")
print_response "$verify_response"
unset otp new_password request_body request_response verify_body verify_response
