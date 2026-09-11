#!/usr/bin/env bash
# Gate for the Authentik proxy outpost pin. Called by validate.yml on every
# change and by authentik-sync.yml before it merges a new version.
#
# Deliberately light: that a given Authentik version works as a server/outpost
# pair is proven where the server version is chosen, and by the time this runs
# the server is already serving that version. What is left to prove here is that
# the tag exists, that the compose file and .authentik-ref agree, and that the
# health check command still exists inside the image -- an image that lacks it
# fails every probe silently and leaves the whole app "running:unhealthy".
set -euo pipefail

version="${1:-$(cat .authentik-ref)}"
image="ghcr.io/goauthentik/proxy:${version}"

fail() { echo "::error::$*" >&2; exit 1; }

echo "==> pin consistency"
grep -q "AUTHENTIK_TAG:-${version}}" compose.yml \
  || fail "compose.yml does not pin AUTHENTIK_TAG to ${version}"

echo "==> ${image} exists"
docker pull --quiet "$image" >/dev/null || fail "cannot pull ${image}"

echo "==> health check command from compose.yml runs inside the image"
export MARIADB_SERVER=ci-dummy MARIADB_PASSWORD=ci-dummy \
       AUTHENTIK_HOST=https://authentik.invalid AUTHENTIK_OUTPOST_TOKEN=ci-dummy
mapfile -t test_cmd < <(
  docker compose -f compose.yml config --format json \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["services"]["outpost"]["healthcheck"]["test"][1:]))'
)
[ "${#test_cmd[@]}" -gt 0 ] || fail "no health check command found for the outpost service"
echo "    ${test_cmd[*]}"

set +e
out="$(docker run --rm --entrypoint "${test_cmd[0]}" "$image" "${test_cmd[@]:1}" 2>&1)"
rc=$?
set -e
# 125/126/127 are docker's own "could not start it": image config broken, not
# executable, or not there at all. Any other code means the command ran -- it is
# expected to fail here, because there is no Authentik server to talk to.
case "$rc" in
  125|126|127) printf '%s\n' "$out"; fail "health check command is missing from ${image}" ;;
esac
echo "    command present (exit ${rc} without a server, as expected)"

echo "OK"
