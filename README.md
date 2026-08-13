# Fast Duplicate Finder

**English** | **[简体中文](README.zh-CN.md)**

A native **macOS** app that finds and removes **duplicate files** on local disks and network volumes (NAS) — fast by default, with safety checks before cleanup.

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.3-blue" alt="version" />
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="platform" />
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-green" alt="arch" />
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="license" />
</p>

## Features

- **Turbo scan** — Size buckets + xxHash sampling; optional **Precise compare** (full-file) for groups marked **Needs review**
- **Packages as wholes** — `.app`, disc packages, etc. stay opaque; compared as single items (structure + light content checks)
- **Purpose-risk safety** — Same content but different *role* (locale paths, multi-product `CodeResources`, wrapper shells) is flagged and **not** pre-checked for delete
- **User-controlled cleanup** — Checkbox selection per item; Clean Up uses your marks; Trash by default
- **Network / NAS aware** — Lower concurrency, path-ordered hashing, sequential-friendly network path
- **Scan cache** — Reuse hashes across runs; package fingerprints skip interior walks when mtime is unchanged
- **Modern UI** — Dense outline results, filters (All / Needs review / Packages), search, timing breakdown
- **Language** — English & Simplified Chinese, **follows macOS Language & Region** (no in-app language switch)
- **Settings** — Gear or **⌘,** (standard Settings window)

## Requirements

- macOS **13** or later  
- **Apple Silicon** recommended (`build.sh` targets `arm64`)

## Installation

### Download (recommended)

Download the latest **`FastDuplicateFinder.zip`** from the
[Releases](https://github.com/kDolphin/Fast_Duplicate_Finder/releases) page:

1. Unzip the file  
2. Drag **`Fast Duplicate Finder.app`** into `/Applications`  
3. First launch: right-click the app → **Open** (ad-hoc signed, not notarized)

[Older releases →](https://github.com/kDolphin/Fast_Duplicate_Finder/releases)

### Build from source

```bash
git clone https://github.com/kDolphin/Fast_Duplicate_Finder.git
cd Fast_Duplicate_Finder
bash build.sh
open "build/Fast Duplicate Finder.app"
```

Install to Applications:

```bash
cp -R "build/Fast Duplicate Finder.app" /Applications/
```

### Xcode (optional)

```bash
open finddup.xcodeproj
# Scheme: finddup · Product: Fast Duplicate Finder
```

## How to use

1. Add one or more folders in the sidebar.  
2. Click **Start Scan**.  
3. Review groups: expand, mark items to delete (or leave purpose-risk groups unchecked).  
4. Use **Compare needs review** when you want full-file confirmation.  
5. **Clean Up** → preview → Trash / permanent per Settings.  

Settings: **⌘,** or the gear icon.

## Changelog

### 1.0.3

- **Results UI** — Expand/collapse all is O(1) (no freeze on 10k–40k groups); purpose-risk badge keys precomputed
- **Clean Up** — Button count and delete batch respect the current filter (All / Needs review / Packages) and search
- **Settings cache** — Entry count updates immediately after scan or clear (no app relaunch required)

### 1.0.2

- **NAS enumeration** — Parallel first-level subtree listing (concurrency **6**); reuse package metadata to avoid extra SMB RTTs
- **Large-library prepare / finalize** — Faster list fingerprints, in-memory hash cache, no incomplete snapshot on cancel; group assembly without filesystem path resolution; async cache write
- **Purpose-risk cleanup UX** — Toolbar **Apply keep suggestions** and per-group **Mark others** (still unchecked by default for safety)
- **Scan timing** — Breakdown bars sum to wall-clock total; clearer multi-minute duration format

### 1.0.1

- **NAS performance** — Three-point sample windows reduced to **12 KB**; network hash concurrency fixed at **6**
- **Cancel / resume** — Stopping a scan no longer publishes an incomplete result snapshot (which made the next run look “done” too early). Partial per-file hashes are still kept for faster resume

### 1.0.0

- Initial public release

## Known limitations (v1.0)

| Topic | Detail |
|-------|--------|
| Sandbox | Only folders you grant access to can be scanned |
| Signing | Ad-hoc signature; not notarized by Apple |
| Heuristics | Purpose-risk rules are path/name heuristics; rare false positives/negatives possible |
| Architecture | `build.sh` is arm64-focused |

## Privacy

| Action | Detail |
|--------|--------|
| Read | Folders you select (App Sandbox + user-selected files) |
| Write | Only when you confirm cleanup |
| Network | Only mounted volumes you choose to scan |
| Cloud | **Nothing uploaded** — all work stays on your Mac |

## Project layout

```text
finddup/                 # App sources, assets, localizations
  Models/  Services/  Views/
  en.lproj/  zh-Hans.lproj/
build.sh                 # → build/Fast Duplicate Finder.app + zip
finddup.xcodeproj
LICENSE
```

## Stack

- Swift / SwiftUI  
- CryptoKit + custom xxHash  
- **No third-party dependencies**

## Build outputs

```bash
bash build.sh
# → build/Fast Duplicate Finder.app
# → build/FastDuplicateFinder.zip
```

## Troubleshooting

| Issue | Try |
|-------|-----|
| Permission denied | Re-select the folder when prompted |
| Slow on NAS | Keep the volume mounted; first full scan warms the cache |
| Language wrong | Change system / per-app language in **System Settings → Language & Region**, then relaunch |
| Build fails | Use full Xcode (not only CLT); run `bash build.sh` from the repo root |

## License

[MIT](LICENSE) © contributors

## Repository

[github.com/kDolphin/Fast_Duplicate_Finder](https://github.com/kDolphin/Fast_Duplicate_Finder)
