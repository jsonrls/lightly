# Mac Cleaner

A native macOS menu bar app that cleans junk by itself and shows disk, memory, CPU and battery at a glance.

It runs once a day at 03:00, or at the next wake if the Mac was asleep. There is nothing to press.

## What it cleans

- App caches, in `~/Library/Caches`, skipping any app that is open
- Logs older than 7 days, keeping crash reports
- Trash items older than 30 days (needs Full Disk Access)
- Leftovers from apps that have been gone for 30 days, moved to the Trash first
- Developer caches once a week: npm, yarn, pnpm, pip, Homebrew, Xcode DerivedData
- Docker build cache and dangling images, only when Docker's data is on the internal disk

## What it never touches

- External drives
- Documents, Desktop, Downloads, Photos, Mail or browser profiles
- System folders. It never asks for an admin password.

Every deletion goes through one gateway, `DeletionGateway`, which refuses anything outside these rules.

**Cleaning is permanent and needs no confirmation.** Read the dry-run list before you run a live build.

## Apple Intelligence

On Macs that support it, the on-device model describes each clean in plain words and answers questions such as "What's using my disk?". It only rewords measured facts. It has no tools, it cannot decide what gets deleted, and its answers are checked against those facts. Nothing leaves your Mac.

## Build

Requires macOS 27 and Xcode 27.

```bash
swift test
scripts/bundle.sh
```

`scripts/bundle.sh` builds `dist/Mac Cleaner.app` as a **dry run**, which deletes nothing. To see what a clean would remove:

```bash
"dist/Mac Cleaner.app/Contents/MacOS/MacCleaner" --dry-run-report
```

The list is written to `~/Library/Application Support/com.maccleaner.app/dry-run.txt`.

Only `scripts/bundle.sh --live` makes a build that really deletes. Copy that build to `/Applications` and launch it from there, because the login item stays tied to where the app first ran.

## Design

The design and plan are in `docs/superpowers/`.
