#!/usr/bin/env bash
# Run every sandbox test in order; print a summary table at the end.
# Each test is independent — failures don't abort the suite.
set -uo pipefail

cd "$(dirname "$0")"
RESULTS=()

for s in 01-tilt.sh 02-devcontainers.sh 03-dind.sh 04-postgres.sh 05-elasticsearch.sh 06-playwright.sh 07-kind.sh; do
  echo
  echo "=================================================="
  echo ">>> $s"
  echo "=================================================="
  start=$(date +%s)
  if bash "$s"; then
    status=PASS
  else
    status=FAIL
  fi
  dur=$(( $(date +%s) - start ))
  RESULTS+=("$status  $(printf '%-22s' "$s")  ${dur}s")
done

echo
echo "=================================================="
echo "SUMMARY"
echo "=================================================="
printf '%s\n' "${RESULTS[@]}"

# Exit non-zero if anything failed
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1 || exit 0
