#!/usr/bin/env bash
# Boots a throwaway T3 Code server from npm (`t3@<tag>`) and runs Tea Three's
# live contract tests against it. No provider logins needed: the tests never
# run a model. Used by CI nightly; works the same on a Mac.
#
#   scripts/contract-against-npm.sh latest
#   scripts/contract-against-npm.sh nightly
#   scripts/contract-against-npm.sh 0.1.9
set -euo pipefail

tag="${1:-latest}"
port="${T3_CONTRACT_PORT:-3989}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/tea-three-contract.XXXXXX")"
log="$work/serve.log"
mkdir -p "$work/home" "$work/cwd"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

echo "::group::Start t3@$tag"
(cd "$work/cwd" && T3CODE_HOME="$work/home" npx --yes "t3@$tag" serve \
  --base-dir "$work/home" --host 127.0.0.1 --port "$port" --no-browser >"$log" 2>&1) &
server_pid=$!

for _ in $(seq 1 120); do
  if grep -q "Pairing URL:" "$log" 2>/dev/null; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$log"; echo "t3 serve exited early" >&2; exit 1; fi
  sleep 1
done
pairing_url="$(grep -m1 "Pairing URL:" "$log" | sed -E 's/.*Pairing URL: *//' | tr -d '[:space:]')"
if [[ -z "$pairing_url" ]]; then cat "$log"; echo "no pairing URL printed" >&2; exit 1; fi
version="$(curl -fsS "http://127.0.0.1:$port/.well-known/t3/environment" | sed -E 's/.*"serverVersion":"([^"]+)".*/\1/')"
echo "t3@$tag is $version on :$port"
echo "::endgroup::"

cd "$repo_root/Packages/TeaThreeKit"
T3_CONTRACT_PAIRING_URL="$pairing_url" swift test --filter LiveContractTests
echo "Tea Three is compatible with T3 Code $version (t3@$tag)"
