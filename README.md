<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo/lightly-logo-on-dark.png">
    <img src="design/logo/lightly-logo-on-light.png" alt="Lightly" width="360">
  </picture>
</p>

A native macOS menu bar app that cleans junk by itself. There is nothing to press.

It lives in the menu bar as a small white logo and runs every 3 hours, day and night, or at the next wake if the Mac was asleep.

## What you see

- **Menu bar window:** click the logo for disk, memory, CPU and battery as rings, plus the last clean and a "Clean now" button.
- **Full view:** larger rings, the last clean by category, a paged cleaning history, and the Apple Intelligence ask box.
- **Settings:** the gear icon opens them.

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
- Anything you add to the "Always kept" list

Every deletion goes through one gateway, `DeletionGateway`, which refuses anything outside these rules.

**Cleaning is permanent and needs no confirmation.** Read the dry-run list before you run a live build.

## Settings

- Open at login
- Use Apple Intelligence
- Clean automatically, and how often: every hour, 3, 6 or 12 hours, or once a day
- What to clean: a switch for each category
- Always kept: files and folders that are never cleaned
- Full Disk Access status

## Apple Intelligence

On Macs that support it, the on-device model describes each clean in plain words and answers questions such as "What's using my disk?". A Scan button finds the biggest items and explains what they probably are.

It only rewords measured facts. It has no tools, it cannot decide what gets deleted, and its answers are checked against those facts. An answer that fails the check is replaced by the facts. Nothing leaves your Mac, and you can switch it off in Settings.

## Build

Requires macOS 27.

```bash
swift test
scripts/bundle.sh
```

`scripts/bundle.sh` builds `dist/Lightly.app` as a **dry run**, which deletes nothing. To see what a clean would remove:

```bash
"dist/Lightly.app/Contents/MacOS/MacCleaner" --dry-run-report
```

The list is written to `~/Library/Application Support/com.maccleaner.app/dry-run.txt`.

## Install

Only `scripts/bundle.sh --live` makes a build that really deletes.

1. Run `scripts/bundle.sh --live`.
2. Copy `dist/Lightly.app` to `/Applications` and launch it from there, because the login item stays tied to where the app first ran.
3. Turn on Full Disk Access in System Settings so the Trash can be cleaned.

The first automatic clean waits 3 hours after the first launch.

## Design

The design and plan are in `docs/superpowers/`. Logo files are in `design/logo/`.
