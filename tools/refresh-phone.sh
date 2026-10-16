#!/bin/zsh
# Rebuilds and reinstalls Receipts on your iPhone so the free 7-day signing never lapses.
# Run daily by ~/Library/LaunchAgents/com.kolincunningham.receipts-refresh.plist; only acts
# when the last successful install is 4 or more days old and the phone is reachable.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
PROJECT="${0:A:h:h}"
source "$PROJECT/tools/local.env" || exit 1   # sets DEVICE (git-ignored, see local.env.example)
STAMP="$HOME/Library/Application Support/ReceiptsRefresh/last-success"
BUILD="$HOME/Library/Caches/ReceiptsRefresh"
mkdir -p "${STAMP:h}" "$BUILD"
echo "=== $(date)"

if [[ -f "$STAMP" && "$1" != "--force" ]]; then
  age=$(( ($(date +%s) - $(stat -f %m "$STAMP")) / 86400 ))
  if (( age < 4 )); then echo "Installed $age days ago, nothing to do."; exit 0; fi
fi

if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -q "connected\|available"; then
  echo "iPhone not reachable (needs same Wi-Fi or cable). Will try again tomorrow."
  osascript -e 'display notification "Connect your iPhone to the Mac or the same Wi-Fi so Receipts can renew." with title "Receipts"' 2>/dev/null
  exit 0
fi

cd "$PROJECT" || exit 1
# Scans come first: copy each app's data to the Mac, and do not install unless that worked.
for APPID in com.kolincunningham.ReceiptScanner com.kolincunningham.Ledger; do
  if ! "$PROJECT/tools/backup-phone.sh" "$APPID"; then
    echo "Backup of $APPID failed, so nothing was reinstalled."
    osascript -e 'display notification "Backup of your receipts failed, so the apps were not updated. Unlock the iPhone and it will retry tomorrow." with title "Receipts"' 2>/dev/null
    exit 1
  fi
done

ok=1
for SCHEME in ReceiptScanner Ledger; do
  if ! xcodebuild -project ReceiptScanner.xcodeproj -scheme "$SCHEME" -configuration Release \
       -destination "id=$DEVICE" -allowProvisioningUpdates -derivedDataPath "$BUILD" build -quiet; then
    echo "Build of $SCHEME failed."; ok=0; continue
  fi
  if xcrun devicectl device install app --device "$DEVICE" "$BUILD/Build/Products/Release-iphoneos/$SCHEME.app" >/dev/null; then
    echo "Installed $SCHEME."
  else
    echo "Install of $SCHEME failed (phone locked or asleep?)."; ok=0
  fi
done

if (( ok )); then
  touch "$STAMP"
else
  osascript -e 'display notification "Receipts or Ledger could not renew. It will retry tomorrow, or open Xcode and press Run." with title "Receipts"' 2>/dev/null
fi
