#!/usr/bin/env bash
# Fails if any commit in the given range lacks a Signed-off-by trailer for its author
# (Developer Certificate of Origin). Release bump commits from github-actions[bot] are exempt.
set -euo pipefail
range="${1:-HEAD}"
fail=0
while read -r sha; do
  author="$(git log -1 --format='%an <%ae>' "$sha")"
  case "$author" in *"github-actions[bot]"*) continue ;; esac
  if ! git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha" | grep -Fqx "$author"; then
    echo "::error::$sha has no 'Signed-off-by: $author' (commit with -s)"; fail=1
  fi
done < <(git rev-list --no-merges "$range")
exit $fail
