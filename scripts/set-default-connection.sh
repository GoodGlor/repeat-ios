#!/usr/bin/env bash
# Bake a default Google connection into the build (#78).
#
#   scripts/set-default-connection.sh ~/Downloads/service-account-key.json \
#       "https://docs.google.com/spreadsheets/d/<id>/edit"
#
# Writes Config/DefaultConnection.json, which is gitignored and copied into the
# app bundle at build time. A fresh install then arrives already connected.
#
# The key file itself stays where you downloaded it. Do not move it into the
# repository: a key in git history is permanent, and a private repo is not a
# secret store.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <service-account-key.json> <sheet-url-or-id>" >&2
    exit 2
fi

key_path="$1"
sheet="$2"
out="Config/DefaultConnection.json"

[[ -f "$key_path" ]] || { echo "no such key file: $key_path" >&2; exit 1; }

# Refuse a key that lives inside the repository — that is the one thing this
# script must never help someone do.
repo_root="$(pwd -P)"
key_dir="$(cd "$(dirname "$key_path")" && pwd -P)"
case "$key_dir/" in
    "$repo_root"/*) echo "refusing: the key is inside the repository ($key_path)." >&2
                    echo "Move it outside the repo and rerun." >&2
                    exit 1 ;;
esac

python3 - "$key_path" "$sheet" "$out" <<'PY'
import json, re, sys

key_path, sheet, out = sys.argv[1], sys.argv[2], sys.argv[3]

with open(key_path) as handle:
    account = json.load(handle)

missing = [f for f in ("type", "client_email", "private_key") if not account.get(f)]
if missing:
    sys.exit(f"{key_path} is missing: {', '.join(missing)} — is it a service-account key?")
if account.get("type") != "service_account":
    sys.exit(f"{key_path} has type {account.get('type')!r}, expected 'service_account'.")

# Accept the whole sheet URL as readily as a bare id; the app does the same.
match = re.search(r"/spreadsheets/d/([^/?#]+)", sheet)
sheet_id = match.group(1) if match else sheet.strip()
if len(sheet_id) < 20:
    sys.exit(f"{sheet_id!r} does not look like a spreadsheet id.")

with open(out, "w") as handle:
    json.dump({"spreadsheetId": sheet_id, "serviceAccount": account}, handle, indent=2)

print(f"wrote {out}")
print(f"  sheet   {sheet_id}")
print(f"  account {account['client_email']}")
print()
print(f"Share the sheet with {account['client_email']} as an Editor,")
print("then rebuild. A fresh install will already be connected.")
PY

git check-ignore -q "$out" || {
    echo >&2
    echo "WARNING: $out is NOT gitignored. Do not commit it." >&2
    exit 1
}
