# Sticky Panel — Flutter branch

A small, portable, always-on-top note and checklist for Windows. This branch replaces the WinUI 3 implementation with Flutter and uses a calm, Apple-inspired visual language.

The original WinUI 3 version remains untouched on [`main`](https://github.com/Nakiha/Sticky-Panel/tree/main).

## Current features

- Frameless, resizable, always-on-top panel
- Native Windows Acrylic with light, dark, and system themes
- Editable list title, free-form note, and checklist
- Completed items fade and receive a strikethrough
- Live completion progress and four task priorities
- Adjustable text size and regular, medium, or bold weight
- Automatic Chinese or English localization with a manual override
- Unicode, Chinese, Japanese, and emoji font fallback
- Automatic portable JSON storage beside the executable
- Window position, size, and pin state persistence
- `Ctrl + Enter` to add a checklist item
- No .NET or Windows App Runtime dependency

## Download

Open the latest successful [Flutter build](https://github.com/Nakiha/Sticky-Panel/actions/workflows/build.yml?query=branch%3Aflutter), download `StickPanel-windows-x64-portable`, and extract the ZIP before running `StickPanel.exe`.

The EXE must stay beside its `data` directory and Flutter DLLs. User content is written to `StickPanel.data.json` in that same folder.

## Build locally

Install the current Flutter stable SDK with Windows desktop support, then run:

```powershell
flutter create --platforms=windows --project-name stick_panel --org io.github.nakiha .
flutter pub get
flutter run -d windows
```

Release build:

```powershell
flutter build windows --release
```

## Notes

- Windows x64 is the supported release target for now.
- Acrylic requires Windows 10 1803 or newer. The interface remains usable if the system falls back to a solid composition surface.
- Running from a protected directory such as `Program Files` can prevent portable data writes. Extract to a user-writable folder.
- Existing version 1 `StickPanel.data.json` files are migrated in place when new settings are saved.

## License

MIT
