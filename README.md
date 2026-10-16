# Receipts (iPhone + Mac)

Scan receipts, file them under a company, let Apple Intelligence classify them, import bank
statements, and match receipts to bank transactions. Exports an Excel workbook.
Includes a Xero style ledger (Australian chart of accounts, GST/BAS, Profit & Loss) and an
"Import from Xero" reader. Everything stays on your devices; nothing is sent to a server.

## Download
- **Mac:** download `Receipts-Ledger-mac.zip` from the [latest release](../../releases/latest), unzip, and
  move **Receipts & Ledger** to Applications. It is not notarised by Apple, so the first time,
  right-click the app and choose **Open** (or System Settings > Privacy & Security > Open Anyway).
  Needs macOS 26.
- **iPhone:** Apple only allows iPhone apps through the App Store or TestFlight, so build it
  yourself with Xcode (free Apple ID is enough), as below. Needs iOS 26.

## Build it yourself
1. Install Xcode 26 or later and XcodeGen (`brew install xcodegen`).
2. `cp tools/local.env.example tools/local.env` and fill in your team id (Xcode > Settings >
   Accounts) and, for the phone scripts, your iPhone's device id (`xcrun devicectl list devices`).
3. Optional: `cp Shared/Config/CompanyDefaults.example.json Shared/Config/CompanyDefaults.json` and
   list your own companies. Both files are git-ignored.
4. `set -a; source tools/local.env; set +a; xcodegen generate`, then open `ReceiptScanner.xcodeproj`
   and run the `ReceiptScanner`, `Ledger` or `ReceiptsMac` scheme. Change the bundle id prefix in
   `project.yml` if Xcode says the ids are taken.

## Apps
- **Receipts** on iPhone (scheme `ReceiptScanner`): company wheel, Scan receipt, Find receipts in Photos, Import from Files.
- **Ledger** on iPhone (scheme `Ledger`): Reconcile, Bank (accounts and statement import), Reports
  (Profit & Loss, GST/BAS), Chart of Accounts, Settings (sync, companies).
- **Receipts & Ledger** on Mac (scheme `ReceiptsMac`): everything in one sidebar.
All three share data through the Receipts Library folder in iCloud Drive (Sync settings in each app).

## Sync between iPhone and Mac (free, through iCloud Drive)
iPhone: Receipts tab > table icon > Sync with Mac. Mac: sidebar > Sync with iPhone.
Choose the same folder on both (create iCloud Drive > Receipts Library the first time).
Syncs on open, after changes and every 2 minutes. After reinstalling the app, choose the folder
again and everything comes back. Deletions of more than 5 records at once ask first.

## Bank statements
1. Bank tab > + > add each account (business or personal) and pick its company.
2. In internet banking, export the account's transactions as CSV (or OFX/QFX).
   CommBank, Westpac, NAB, ANZ, Macquarie, ING and Up all work. Overlapping ranges are fine.
3. Open the account > Import statement.
Matching: same amount, posted 0 to 7 days after the receipt, name similarity. Certain matches link
automatically; others appear on the Match tab to accept or skip. Transfers, bank fees and money in
are marked "No receipt needed". Categories: your corrections > matched receipt > rules > Apple Intelligence.

## Spreadsheet
Sheets: Summary, All Receipts, Bank Transactions, Missing Receipts, one per company.
iPhone: Files > On My iPhone > Receipt Scanner > Receipts.xlsx, or the table icon > Share.

## Free Personal Team: weekly renewal
Free builds expire after 7 days. `tools/refresh-phone.sh` runs daily at 8:30 pm (LaunchAgent
`com.kolincunningham.receipts-refresh`) and reinstalls when the last install is 4+ days old and
the iPhone is on the same Wi-Fi or plugged in. Log: ~/Library/Logs/ReceiptsRefresh.log.
For Wi-Fi installs: Xcode > Window > Devices and Simulators > your iPhone > tick "Connect via network".
Run `tools/refresh-phone.sh --force` to reinstall now.
Remove: `launchctl bootout gui/$(id -u)/com.kolincunningham.receipts-refresh`.

## Turning iCloud on (paid Developer Program team)
In `project.yml`:
1. Set DEVELOPMENT_TEAM to the paid team and add `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ICLOUD"`.
2. Both targets: entitlements `com.apple.developer.icloud-container-identifiers` and
   `com.apple.developer.ubiquity-container-identifiers` = [iCloud.com.kolincunningham.ReceiptScanner],
   `com.apple.developer.icloud-services` = [CloudKit, CloudDocuments], `aps-environment: development`
   (Mac: `com.apple.developer.aps-environment`).
3. iPhone Info.plist: `UIBackgroundModes: [remote-notification]` and `NSUbiquitousContainers` for the
   container (DocumentScopePublic true, name "Receipt Scanner").
4. `xcodegen generate`. iPhone and Mac then share one iCloud database and the spreadsheet lives in
   iCloud Drive > Receipt Scanner.

## Testing
Debug builds accept `-demoData` (sample receipts and a CommBank statement) and `-startBank` / `-startMatch`.
Project files are generated from `project.yml` with XcodeGen.

## Licence
MIT, see [LICENSE](LICENSE). No warranty: check your own tax figures with your accountant.
