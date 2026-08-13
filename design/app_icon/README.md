# App icon sources

- `layers/` contains the three 1024×1024 SVG components used by Apple Icon Composer.
- `macos/Runner/AppIcon.icon` stores those components front-to-back as pin/ink, note sheet, and rear panel groups so Liquid Glass depth renders correctly.
- `sticky-panel-flat.svg` is the deterministic flat version used for legacy macOS PNGs and the Windows icon.

Run `./design/app_icon/render_icons.sh` on macOS to regenerate the asset-catalog PNGs and the seven-resolution Windows `.ico` file. The script requires the system `sips` command and `ffmpeg`.
