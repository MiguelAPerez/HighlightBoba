#!/usr/bin/env bash
# Fails if any commit in the given range has an author or committer email that is
# not a GitHub noreply address, or mentions a blocked domain anywhere in its metadata.
set -euo pipefail
range="${1:-HEAD}"
blocked='miguelaperez\.dev'
allowed='^([0-9]+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com$|^noreply@github\.com$'
fail=0
while IFS=$'\t' read -r sha ae ce; do
  for e in "$ae" "$ce"; do
    if ! [[ "$e" =~ $allowed ]]; then
      echo "::error::$sha uses a non-noreply email"; fail=1
    fi
  done
done < <(git log --format='%H%x09%ae%x09%ce' "$range")
if git log --format='%an%n%ae%n%cn%n%ce%n%B' "$range" | grep -Eiq "$blocked"; then
  echo "::error::a commit in $range mentions a blocked domain"; fail=1
fi
if git grep -Eiq "$blocked" -- . ':!scripts/check-commit-emails.sh'; then
  echo "::error::the tree mentions a blocked domain"; fail=1
fi
exit $fail
