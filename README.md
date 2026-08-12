# Stick Panel

A small, modern, always-on-top checklist for Windows. It is built with native
WinUI 3, follows the system light/dark theme, supports Unicode and emoji, and
saves everything beside the executable.

## Features

- Native Windows 11 acrylic backdrop and per-monitor DPI support
- Editable checklist with completed-task state and quick cleanup
- Always-on-top toggle (`Ctrl+Shift+A`)
- Automatic, atomic JSON saves beside `StickPanel.exe`
- Window position and size restoration across displays
- Portable, unpackaged, self-contained single-file EXE
- x64 and ARM64 builds from GitHub Actions

## Download

Open the repository's **Actions** tab, choose the latest successful
**Build portable EXE** run, and download `StickPanel-win-x64`. Tagged builds
are also attached to GitHub Releases.

The first launch can take a little longer because the self-contained WinUI 3
runtime is extracted to a temporary directory. No installer or separately
installed Windows App SDK runtime is required.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Enter` | Focus the new-task box |
| `Ctrl+Shift+A` | Toggle always on top |
| `Ctrl+S` | Save immediately |
| `Enter` in a task | Focus the new-task box |
| `Shift+Enter` in a task | Insert a new line |

## Local build

Requirements: Windows 10 1809 or later and the .NET 10 SDK.

```powershell
dotnet publish src/StickPanel/StickPanel.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:Platform=x64 -p:PublishSingleFile=true
```

## Data

`StickPanel.data.json` is created next to the EXE. Keep the executable in a
writable folder if you want fully portable behavior. A malformed JSON file is
preserved with a `.broken-<timestamp>` suffix before a fresh state is created.

## License

MIT
