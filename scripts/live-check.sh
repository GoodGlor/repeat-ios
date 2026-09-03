#!/bin/zsh
# Runs the Sheets checks that need a real key and a real spreadsheet.
#
# Reads Config/live.env, which is gitignored and only records *where* the key is.
# The key stays outside the repository: a key in git history is permanent, and a
# private repo is not a secret store.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT=$(git rev-parse --show-toplevel)
if [[ ! -f "$ROOT/Config/live.env" ]]; then
  echo "Config/live.env not found. Copy Config/live.env.template and fill it in."
  exit 1
fi
source "$ROOT/Config/live.env"

if [[ ! -f "${REPEAT_LIVE_KEY_PATH:-}" ]]; then
  echo "REPEAT_LIVE_KEY_PATH does not point at a file: ${REPEAT_LIVE_KEY_PATH:-<unset>}"
  exit 1
fi

echo "==> live Sheets check against ${REPEAT_LIVE_SHEET_ID}"
(cd "$ROOT/Packages/GoogleSheets" \
  && swift test --filter LiveSheetsTests 2>&1 \
  | grep -E "\[live\]|error:|XCTAssert|skipped|Executed .* test")

if [[ "${1:-}" == "--with-app" ]]; then
  echo "==> live pull into SwiftData (simulator)"
  # The key is forwarded as *contents*, not a path: the test runs inside the
  # simulator's sandbox and cannot read the host's filesystem. TEST_RUNNER_ vars
  # are forwarded to the test process with the prefix stripped, and must be
  # exported rather than passed as build settings.
  export TEST_RUNNER_REPEAT_LIVE_KEY_JSON="$(cat "$REPEAT_LIVE_KEY_PATH")"
  export TEST_RUNNER_REPEAT_LIVE_SHEET_ID="$REPEAT_LIVE_SHEET_ID"
  cd "$ROOT"
  xcodegen generate >/dev/null
  xcodebuild -project Repeat.xcodeproj -scheme Repeat \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:RepeatTests/LivePullTests test 2>&1 \
    | grep -E "\[live\]|error:|XCTAssert|skipped|Executed .* test|\*\* TEST"
fi
