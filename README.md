# Dürücü

A native macOS archive app. Double-clicking a zip in Finder no longer dumps its contents next to it:
Dürücü shows you what's inside first, so you extract only what you need. It also creates archives
and lets you add or remove files in existing ones.

The name is Turkish for "the one who rolls things up", like a dürüm wrap.

## Install

```sh
brew install --cask falconsw/tap/durucu
```

Or download the DMG from [Releases](https://github.com/falconsw/durucu/releases). Requires macOS 26 or later.
Builds are signed with a Developer ID and notarized by Apple.

On first launch Dürücü makes itself the default app for archive files, so double-clicking one in Finder
opens Dürücü instead of Archive Utility. To undo this, right-click a zip › Get Info › Open with ›
Archive Utility › Change All.

## Features

- **Open:** ZIP, 7Z, RAR/RAR5, TAR, TAR.GZ/XZ/BZ2, GZ, XZ, ISO, CPIO
- **Browse:** folder tree, sortable list, search, compression savings per file, Quick Look (Space), inspector preview
- **Extract:** everything or just the selection; smart folder; never overwrites (adds " 2"); drag files out to Finder
- **Edit:** add files and folders (drag and drop or ⇧⌘A), delete the selection (⌘⌫). Works for ZIP, 7Z and TAR;
  the previous version goes to the Trash
- **Create:** ZIP (with AES-256 password), 7Z, TAR.GZ, TAR.XZ; leaves out macOS clutter (`.DS_Store`, `._*`, `__MACOSX`)
- Reads zips made on older Windows machines with Turkish (CP857) file names correctly
- Finder context menu: **Compress with Dürücü** and **Extract Here with Dürücü**
- English and Turkish, switchable in Settings › General (English by default)

## Building from source

Requires Xcode 26+, macOS 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # generates Durucu.xcodeproj from project.yml
open Durucu.xcodeproj
./scripts/install.sh       # Release build installed to /Applications/Durucu.app
./scripts/release.sh       # Developer ID signed, notarized DMG in dist/
```

The app icon is drawn by `scripts/make-icon.swift`:
`swift scripts/make-icon.swift Durucu/Resources/Assets.xcassets/AppIcon.appiconset`

## Project layout

| Folder | Contents |
| --- | --- |
| `Durucu/Engine` | libarchive bridge (`CLibArchive`), reading/extracting, writing, editing, ZIP central directory |
| `Durucu/Models` | Window models, archive tree, extraction service, preview cache |
| `Durucu/Views` | SwiftUI screens (welcome, browser, new archive, settings) |
| `Durucu/App` | App lifecycle, window management, Finder services |
| `Durucu/Resources` | Assets, `Localizable.xcstrings` (English source, Turkish translation) |

The archive engine uses the `libarchive` that ships with macOS. The SDK has no headers for it, so the
functions Dürücü needs are declared in `Engine/CLibArchive/libarchive_shim.h`.

### Translations

UI strings are written in English in code and translated in `Durucu/Resources/Localizable.xcstrings`.
To add a language, add it to the catalog in Xcode, translate, and add its code to `AppLanguage` in
`Support/Preferences.swift` and to `CFBundleLocalizations` in `Info.plist`.

### Debugging layouts

In Debug builds, `open --env DURUCU_SNAPSHOT_DIR=/some/dir -a Durucu.app` writes a PNG of every window
to that folder every two seconds (no screen recording permission needed).

### Promo video

`Durucu --promo-video out.mp4` renders a short promo frame by frame from sample data: 1080p60 for X and
YouTube, or 1080×1920 for Reels and TikTok with `--portrait`. Add `-appLanguage tr` for Turkish.

```sh
APP=/Applications/Durucu.app/Contents/MacOS/Durucu
$APP --promo-video dist/durucu-en.mp4
$APP --promo-video dist/durucu-en-portrait.mp4 --portrait
$APP --promo-video dist/durucu-tr.mp4 -appLanguage tr
$APP --promo-video dist/durucu-tr-portrait.mp4 --portrait -appLanguage tr
```

## License

[MIT](LICENSE)
