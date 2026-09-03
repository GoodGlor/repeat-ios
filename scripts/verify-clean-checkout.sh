#!/bin/zsh
# Builds and tests only what is COMMITTED, in a throwaway checkout.
#
# Exists because of a real incident: a stale `Packages/` line in .gitignore
# silently excluded the whole Scheduling package, so the branch built and tested
# perfectly in its own worktree while main was left referencing a package that
# was not in the repository. Tests passing in a working tree prove nothing about
# what was actually committed.
#
# Run before merging anything that adds files.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

REPO_ROOT=$(git rev-parse --show-toplevel)
REF="${1:-HEAD}"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> exporting $REF to a clean tree"
git -C "$REPO_ROOT" archive "$REF" | tar -x -C "$STAGING"

echo "==> untracked files that the working tree has and the commit does not:"
git -C "$REPO_ROOT" ls-files --others --exclude-standard | sed 's/^/    /' || true

cd "$STAGING"
[[ -f project.yml ]] || { echo "FAIL: project.yml missing from the commit"; exit 1; }

echo "==> xcodegen generate"
xcodegen generate >/dev/null

for package in Packages/*/; do
  name=$(basename "$package")
  echo "==> swift test ($name)"
  PKG_OUT=$(cd "$package" && swift test 2>&1) || { echo "$PKG_OUT" | tail -20; exit 1; }
  echo "$PKG_OUT" | grep -E "Executed [0-9]+ test" | tail -1
  # A suite that runs zero tests is a silent pass, which is the failure mode this
  # script exists to catch.
  echo "$PKG_OUT" | grep -qE "Executed [1-9][0-9]* tests?" || {
    echo "FAIL: package $name ran no XCTest cases"; exit 1; }
done

echo "==> xcodebuild test (app)"
xcodebuild -project Repeat.xcodeproj -scheme Repeat \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath "$STAGING/dd" test 2>&1 \
  | grep -E "error:|Executed .* test|\*\* TEST" | sort -u

echo "==> clean checkout of $REF builds and tests"
