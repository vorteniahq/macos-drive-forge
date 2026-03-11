# FlashForge v2.0 — macOS USB Installer Builder

Polished SwiftUI macOS app to create bootable USB installer drives.

## Features
- List available Apple full installers
- Local installer stash (~/InstallerStash by default)
- Single bootable installer USB creation
- Multi-volume USB drives (e.g., Sonoma + Tahoe on one disk)
- Visual workflow indicator
- Toast notifications for operation feedback
- Drive capacity visualization
- SF Symbols throughout

## Run

### Option A: Terminal
```bash
cd /path/to/usb-installer-v2
swift run FlashForge
```

### Option B: Clickable launcher
- Double-click: `Run-FlashForge.command`
- Or open app directly: `dist/FlashForge.app`

If macOS blocks it (unsigned app), right-click > Open once, then confirm.

## Version History
- v2.0.0 — Polished UI, toast notifications, workflow indicator, drive capacity bar, SF Symbols
- v0.1.0 — Initial functional prototype
