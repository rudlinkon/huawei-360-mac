# Huawei EnVizion 360 (CV60) on macOS

Unofficial macOS driver + viewer for the Huawei EnVizion 360 Panoramic Camera (CV60),
built by reverse engineering the Android app `com.huawei.cvIntl60` 1.9.12.

> Not affiliated with or endorsed by Huawei. "Huawei" and "EnVizion" are trademarks of Huawei
> Technologies Co., Ltd. The app icon is a recoloured version of the camera app's icon
> (`scripts/make-icon.swift <source> Resources/AppIcon.png [hue°]`).

## Install

One command (installs or updates to the latest release in `/Applications`):

```sh
curl -fsSL https://raw.githubusercontent.com/rudlinkon/huawei-360-mac/master/install.sh | bash
```

- Needs an Apple silicon Mac with macOS 15+. Homebrew is not needed; libusb and Syphon are bundled.
- Files downloaded with `curl` are not quarantined, so macOS does not show the "unidentified developer"
  block (the app is ad-hoc signed, not notarized). The script verifies the release checksum and signature.
- While the repository is private, `curl` cannot fetch it: install and log in to the GitHub CLI
  (`brew install gh && gh auth login`), then run `bash install.sh` from a clone — it falls back to `gh`.
- Pin a version: `VERSION=0.1.0 bash install.sh`. Uninstall: `rm -rf "/Applications/Huawei 360.app"`.

Manual install: download `Huawei-360-<version>-macOS-arm64.zip` from [Releases](../../releases),
unzip, move **Huawei 360.app** to Applications, then allow it once in
**System Settings → Privacy & Security → Open Anyway** (browser downloads are quarantined).

The command-line tool is inside the app: `"/Applications/Huawei 360.app/Contents/MacOS/cv60" info`.

## Build

```sh
brew install libusb
./scripts/make-app.sh          # -> dist/Huawei 360.app (self-contained), dist/cv60
VERSION=0.1.0 ./scripts/package-release.sh   # -> dist/Huawei-360-0.1.0-macOS-arm64.zip
```

## Releases (CI)

`.github/workflows/build.yml` builds and packages the app on every push and pull request
(zip attached to the run as an artifact). Pushing a tag `vX.Y.Z` also creates a **draft**
GitHub release with the zip, using the `## [X.Y.Z]` section of `CHANGELOG.md` as notes:

```sh
git tag v0.1.0 && git push origin v0.1.0     # then review and publish the draft on GitHub
```

## Use

1. Plug the camera into the Mac's USB-C port (directly, or via a USB-C cable/adapter).
2. First, test with the CLI:

   ```sh
   dist/cv60 -v info                           # firmware, status, settings
   dist/cv60 dump ~/Desktop/test.h264 10 1920
   dist/cv60 mp4 ~/Desktop/test.h264 ~/Desktop/test.mp4
   dist/cv60 photo ~/Desktop/pano.jpg          # raw camera JPEG (not leveled, no GPano)
   ```

3. Viewer app:

   ```sh
   open "dist/Huawei 360.app"
   ```

   Connect → drag to look around, scroll to zoom, double-click to reset.
   - **Photo**: full-resolution 5376×2688 still taken by the camera (~2.6 s incl. transfer).
     Saved to `~/Pictures/CV60`, leveled for the mount and tagged as a 360° photo (GPano XMP),
     so Google Photos / Facebook show it as a panorama. The untouched camera JPEG goes to
     `~/Pictures/CV60/Originals`.
   - **Snapshot**: quick grab of the live-view frame (1920×960).
   - **Record**: MP4 to `~/Movies/CV60`.

   Launch flags: `--connect` (start streaming), `--webcam` (open the webcam window).

   Test without the camera: `CV60Viewer --play some_dump.h264`.

No sudo needed: the camera's interface is vendor class `0xFF` (it speaks the mass-storage
wire protocol, but macOS does not attach a storage driver to it). Tested with firmware `v1.3B00`:
1920×960 @ ~28 fps, ~5.5 Mbit/s.

**Mount orientation.** The camera's "up" axis runs along its USB plug. Plugged into a Mac's side
port, the panorama therefore arrives rotated 90°. The *Mount* picker (default "Sideways")
re-projects it on the GPU; recordings and snapshots are saved level (recording re-encodes at 16 Mbit/s).

## Use as a webcam (Zoom / Meet / Teams) via OBS + Syphon

A native camera device needs a CoreMediaIO Camera Extension, which macOS only loads when
signed with a paid Apple Developer ID. Instead the viewer publishes a **Syphon** server
("360 Webcam", 1920×1080 or 1280×720, 30 fps) and OBS forwards it through its signed virtual camera.
No window has to stay visible and no screen-recording permission is needed.

1. `brew install --cask obs`
2. Start Huawei 360 and **Connect**. Click **Webcam** to open the preview: drag to aim, scroll to zoom,
   double-click to reset, right-click for view mode / output size / Syphon on-off.
   The preview can be closed afterwards; the Syphon feed keeps the last aim.
3. In OBS: Sources **+** → **Syphon Client** → Source **[Huawei 360] 360 Webcam**.
   Right-click the source → Transform → **Fit to screen**. OBS re-finds it by name after restarts.
4. OBS → **Start Virtual Camera** (first time: allow it in System Settings → General →
   Login Items & Extensions → Camera Extensions).
5. In Zoom / Meet / Teams pick **OBS Virtual Camera**.

Shortcut: `open "dist/Huawei 360.app" --args --connect --webcam`

Syphon (BSD license, `Vendor/Syphon-License.txt`) is vendored as `Vendor/Syphon.xcframework`;
rebuild it with `scripts/build-syphon.sh` (needs `xcodebuild -downloadComponent MetalToolchain`).

## Protocol (reverse engineered)

| Item | Value |
|---|---|
| USB ID | VID `0x12D1` (Huawei), PID `0x109B` |
| Transport | USB Mass Storage Bulk-Only (31-byte CBW `USBC` / 13-byte CSW `USBS`), LUN 0, CDB length 16 |
| Read cmds | vendor opcode `0x7A`, data-in, 64 KiB (keep-alive: 64 bytes) |
| Write cmds | vendor opcode `0x7B`, data-out |
| Reset | class request `0x21 / 0xFF` (BOT mass-storage reset) |
| Response byte 0 | 0 ok · 1 busy · 2 fail · 0xFF power-save (re-open communication) |

| CDB | Meaning |
|---|---|
| `7A 00 01` | open communication (retry while busy) |
| `7A 00 02` (+`[8]=1`, `[12..15]=300`) | close communication |
| `7A 03 FF` | keep-alive (every 500 ms when idle) |
| `7A 03 01` (+app version at `[8]`) | camera info; firmware string at response offset 97 |
| `7A 03 30` | status: `[1]` execution, `[4]` thermal |
| `7A 03 34` / `7A 03 02` | thermal / SCSI version |
| `7A 04 60` / `7B 04 60` (`[4]=48`) | read / write all settings (48 bytes; date at 10–19) |
| `7A 01 01` (`[9]`=res: 10=1280×640, 9=1920×960) | start live view |
| `7A 02 01` | live view ready? (0 = streaming) |
| `7A 05 01` | get live frame piece: `[1]`=last-piece flag, `[4]`=res, `[20]`=thermal, `[28..31]`=len LE, `[32..]`=H.264 Annex-B |
| `7A 01 02` | stop live view |
| `7A 01 03` / `7A 01 04` | start / stop recording (on camera) |
| `7A 01 05` (`[8]`=orientation 0–3) | shutter (live view must be running). Orientation has no visible effect on fw v1.3B00 |
| `7A 02 05` | capture status: `[0]` 0 ready · 1 busy · 3 done, `[2]` 0 = exposure done, `[3]` stored count, `[8..]` file name |
| `7A 05 02` (`[8..11]`=offset LE) | picture piece: `[1]` last flag, `[16..19]` len, `[20..]` JPEG bytes; finish with `7A 05 82` |
| `7A 05 03` | thumbnail JPEG (`[16..19]` len, `[20..]` data) |
| `7A 01 F0` | power off |
| `7A 01 81..85` | firmware update / reset — **not used, risky** |

Live view is already stitched equirectangular (2:1) H.264, so no lens stitching is needed on the Mac.

## Layout

- `Sources/CV60Kit` — libusb transport, SCSI BOT, CV60 protocol, H.264 → CMSampleBuffer, MP4 writer
- `Sources/cv60` — CLI (info / dump / raw / mp4 / off)
- `Sources/CV60Viewer` — SwiftUI + Metal 360° viewer (flat / perspective / little planet)
