# App icon sources

- `layers/` contains the three 1024×1024 SVG components used by Apple Icon Composer.
- `macos/Runner/AppIcon.icon` stores those components front-to-back as pin/ink, note sheet, and rear panel groups so Liquid Glass depth renders correctly.
- `sticky-panel-flat.svg` is the deterministic flat version used for legacy macOS PNGs and the Windows icon.
- `sticky-panel-tray.svg` uses a tighter crop for the tiny Windows tray slot; the regular app/window icon keeps its original breathing room.

Run `./design/app_icon/render_icons.sh` on macOS to regenerate the asset-catalog PNGs and both seven-resolution Windows `.ico` files. The script requires the system `sips` command and `ffmpeg`.
