# Mac Cleaner: design

Date: 2026-11-06
Status: approved by the owner 2026-11-06; reviewer findings folded in afterwards as **(call)** items

Items marked **(call)** were decided by Claude, not by the owner. Everything else the owner said or approved.

## Intent

A Mac cleaner in the spirit of CleanMyMac, but with no buttons to press. It lives in the menu bar, cleans junk by itself in the background, and lets the owner glance at the state of the Mac. The owner already uses an app called CleanUp (`/Applications/CleanUp.app`) and wants the same kind of menu bar monitoring.

Success: the owner never has to think about it. Disk space stays healthy, the menu bar shows live numbers, and nothing the owner cares about is ever lost.

Built for the owner's own Mac first. It will be published to other people later.

## Goals

1. Clean these, and only these, automatically:
   - app caches
   - logs
   - Trash
   - leftover files from deleted apps
   - developer caches: npm, yarn, pnpm, pip, Homebrew, Xcode DerivedData, Docker
2. Show disk, memory, CPU and battery in the menu bar window.
3. Offer a larger "full view" window with history.

## Non-goals (version 1)

- Malware scanning, app uninstaller, large-file finder, duplicate finder.
- Freeing memory or quitting apps. The tiles only monitor.
- Cleaning system folders. No admin password, ever.
- Notifications.
- Mac App Store release, licensing, auto-update, localization.

## Anti-goals

These make the app a failure even if everything else works:

- **Deleting anything on an external volume.** The owner's external drive is `/Volumes/json SSD`. The app touches the internal boot disk only. This includes the Trash folder of any external volume.
- Deleting from Documents, Desktop, Downloads, Photos, Mail, or browser data such as cookies, passwords and history.
- Asking the owner to confirm routine cleaning.
- Letting Apple Intelligence decide what gets deleted. The on-device model only describes a finished run, in the window, and any number it states is checked against the run's facts.

## Cleaning rules

| Category | Where | Rule | How |
|---|---|---|---|
| App caches | `~/Library/Caches` | Skip the cache of any app that is open | Delete |
| Logs | `~/Library/Logs` | Only files older than 7 days; crash reports in `DiagnosticReports` are kept **(call)** | Delete |
| Trash | `~/.Trash` | Only items that entered the Trash 30 or more days ago; hidden files such as `.DS_Store` are kept, because Finder's Put Back needs them **(call)** | Delete |
| App leftovers | See below | App gone for 30 or more days | Move to Trash |
| Developer caches | See below | Once a week **(call)** | Delete |
| Docker | Docker CLI | Build cache and dangling images only | Docker prune commands |

Runs every 3 hours, as the owner asked; the first design said once a day at 03:00. If the Mac was asleep or off when a run was due, it runs at the next wake or launch. Resuming after a pause never triggers a catch-up clean.

Details, all **(call)**:

- **App caches.** A cache folder named after an open app's bundle ID is skipped. Folders that cannot be matched to an app are cleaned only if nothing inside changed in the last 7 days. `com.apple.*` folders are skipped in version 1. A built-in skip list also protects folders whose contents do not come back by themselves (Playwright, Cypress, Electron and Puppeteer browser downloads) and Apple folders without the `com.apple.` prefix (`CloudKit`, `GeoServices`, `PassKit`, `FamilyCircle`, `SiriEntityCache`, `GameKit`, `Animoji`).
- **App leftovers.** The app keeps an inventory of apps installed on the internal disk (`/Applications`, `~/Applications`). When an app disappears from the inventory, the date is recorded. After 30 days gone, files named after that app's bundle ID are moved to the Trash from: `Application Support`, `Caches`, `Preferences`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs` (all under `~/Library`). The Trash rule then removes them 30 days later, so the owner has 60 days in total to notice. If the app comes back, the clock resets. "Gone" means gone from the whole Mac: the clock also resets if macOS can still find the app anywhere (for example moved to an external drive), if it is running, or if any of its files changed in the last 30 days. A leftover holding browser data (`Login Data`, `Cookies`, `places.sqlite`) is kept. Never `com.apple.*`. `Containers` and `Group Containers` are excluded. Known limit: apps deleted before this app was first launched are never cleaned up, and apps installed on external volumes are ignored.
- **Developer caches.** Cleared in full once a week rather than daily, so daily work is not slowed by re-downloads and rebuilds. Xcode DerivedData: only project folders unused for 7 days. A tool with no cache folder is skipped; a cache folder left behind by an uninstalled tool is cleaned as junk. On the owner's Mac today: npm (via nvm), Homebrew, pip and Docker are installed; yarn and pnpm are not, but their cache folders remain.
- **Docker.** Build cache and dangling images only. Never volumes, tagged images or containers. Only when Docker is already running; the app never starts Docker. Skipped if Docker's disk image is not on the internal disk.
- **Clean now** runs every rule, including the weekly ones, with the same age limits.
- **Pause auto-clean** stops scheduled runs until resumed. "Clean now" still works while paused.

## Safety design

All **(call)**, built to enforce the anti-goals:

- **One deletion gateway.** Every delete or move-to-Trash goes through a single function. It refuses unless the fully resolved path is on the boot volume, sits inside an allowed root from the table above, and is not on a deny list (Documents, Desktop, Downloads, Pictures, Movies, Music, Mail, Messages, iCloud Drive, keychains, browser profile data).
- Symbolic links are never followed, and a symbolic link is never a deletion target. A link nested inside a deleted folder goes with the folder; what it points to is untouched.
- A cache location that a tool has redirected to another volume is skipped.
- A dry-run mode lists what would be removed without removing it. Tests use it.
- Every run is recorded: time, category, bytes freed, errors.
- Debug builds are dry-run only, so development never cleans the real home folder. A release build deletes only if it was made with `scripts/bundle.sh --live`.
- Scheduled runs stop while state cannot be saved, because a lost stamp or pause would repeat a clean.
- Installing never deletes at once: the first automatic clean waits 3 hours after first launch.
- A clock moved backwards never triggers a clean.
- A state file that cannot be read is kept aside as `state.corrupt.json`, and the app starts paused, so a lost pause never turns into a clean.
- Before the first real clean on the owner's Mac, the owner reads the dry-run list from that Mac and says yes.

## What the owner sees

Mockups: `.superpowers/brainstorm/80948-1793955094/content/menubar-popover.html` (option B) and `full-window.html`.

**Menu bar item.** Icon plus free space and memory use, for example "212 GB · 61%". No Dock icon. Starts at login.

**Menu bar window** (opens on click):
- Four tiles: disk free, memory used, CPU, battery. Disk means the internal disk only.
- "Last clean" line with time and amount freed. Clicking it shows the breakdown by category.
- "Clean now" button.
- "Open full view" button.
- Gear icon: opens the settings window. Power icon: quits.

**Settings window:** open at login, Apple Intelligence on or off, auto-clean on or off, how often to clean (1, 3, 6, 12 or 24 hours, default 3), a switch for each cleaning category, an "Always kept" list enforced by the gateway, Full Disk Access status, and About.

**Full view window.** A normal resizable window, not fullscreen:
- The same four stats as rings, larger than in the menu bar window. No history graphs: the owner removed them.
- Left panel: last clean, by category.
- Right panel: cleaning history, newest first, five runs per page, with a monthly total. The window's height fits its content; only its width can be resized.
- An ask box for questions such as "What's using my disk?". Apple Intelligence rewords measured facts on device. It has no tools, and any answer with an unmeasured figure or delete advice is replaced by the measured facts.
- "Clean now" and "Pause auto-clean" buttons.

**(call)** Smaller points:
- Fullscreen mode is disabled for the full view window.
- The battery tile is hidden on a Mac with no battery.
- A failed clean shows a warning mark in the menu bar window. No notification.
- Emptying the Trash needs Full Disk Access. On first launch the app explains this and links to the right System Settings pane. Without the permission the app still runs, skips the Trash, and says so in the window.

## How it gets made

Decided by the owner:
- Native Swift app. No Electron.
- Owner's Mac only for now; public later.

**(call)**:
- Swift 6 and SwiftUI, with `MenuBarExtra` for the menu bar. No third-party dependencies.
- Targets macOS 27 (the owner runs macOS 27.2, Xcode 27.2, Apple silicon). Supporting older systems is a publishing-time task.
- Not sandboxed, because the sandbox blocks cleaning other apps' files. Hardened runtime on, so Developer ID signing and notarization can be added later without rework.
- One app process. It schedules its own runs; no separate background daemon.
- State is stored as JSON under `~/Library/Application Support/<bundle id>/`: run history (12 months), app inventory, daily disk samples (30 days). Memory, CPU and battery history lives in memory only.
- Working name "Mac Cleaner". The name must not imitate "CleanMyMac" when published.
- The cleaning rules and the deletion gateway get unit tests against temporary folders. No test ever points at a real user folder.

## Constraints

- The project folder is on the external drive (`/Volumes/json SSD/mac`). The app must never treat its own project location as cleanable.
- The owner's standard pipeline applies where it fits: feature branches, `staging`, then `main`, with CI green before merge. The Vercel preview, staging URL and production deploy stages do not apply to a native Mac app. CI means build plus tests on a macOS runner.

## Left to the builder

- Sampling intervals and menu bar refresh rate, kept light on CPU and battery.
- Exact layout, colors and icon, following the mockups and native macOS conventions.
- File formats and module boundaries, provided the deletion gateway stays the only path to deletion.
- How each developer cache location is found.
- Bundle identifier placeholder.
