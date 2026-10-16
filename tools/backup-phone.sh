#!/bin/zsh
# Copies an app's data (database with every scan, plus Documents) from the iPhone to
# "Phone Backups" next to this project, and checks the copy opens. Exit code 0 means the data is
# safely on the Mac (or the app has no data yet). Run before every install.
# Usage: backup-phone.sh [bundle id]   (default: the Receipts app)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -f "${0:A:h}/local.env" ]] && source "${0:A:h}/local.env"   # sets DEVICE (git-ignored)
: ${DEVICE:?Set DEVICE in tools/local.env (see local.env.example)}
APP=${1:-com.kolincunningham.ReceiptScanner}
ROOT="$(cd "$(dirname "$0")/.." && pwd)/Phone Backups/${APP##*.}"
DEST="$ROOT/$(date +%Y-%m-%d\ %H%M%S)"

if ! xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$APP" 2>/dev/null | grep -q "$APP"; then
  echo "$APP not installed yet, nothing to back up."; exit 0
fi

listing=$(xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" 2>&1)
if [[ $? -ne 0 ]]; then
  if echo "$listing" | grep -qi "not installed\|no such app\|could not find"; then echo "$APP not installed yet, nothing to back up."; exit 0; fi
  echo "Could not reach the app's data on the iPhone:"; echo "$listing" | tail -3; exit 1
fi
if ! echo "$listing" | grep -q "default.store "; then
  echo "$APP has no saved data yet, nothing to back up."; exit 0
fi

mkdir -p "$DEST"
for dir in "Library/Application Support" "Documents"; do
  if echo "$listing" | grep -q "^$dir "; then
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$APP" \
      --source "$dir" --destination "$DEST/${dir:t}" >/dev/null 2>&1 || { echo "Copy of $dir failed."; exit 1; }
  fi
done

STORE=$(find "$DEST" -name default.store -not -path "*/Backups/*" | head -1)
if [[ -z "$STORE" ]] || ! sqlite3 "$STORE" "pragma quick_check" | grep -q '^ok$'; then
  echo "Backup copy is missing or damaged: $DEST"; exit 1
fi
receipts=$(sqlite3 "$STORE" "select count(*) from ZRECEIPT" 2>/dev/null || echo "?")
echo "Backed up $receipts receipts to $DEST"
echo "$receipts" > "$DEST/receipt-count.txt"

# Keep the newest 20 backups.
ls -1d "$ROOT"/*/ 2>/dev/null | sort -r | tail -n +21 | while read -r old; do rm -rf "$old"; done
exit 0
