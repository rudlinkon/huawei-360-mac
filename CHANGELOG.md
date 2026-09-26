# Changelog

## [0.1.0] - 2026-09-27

First release: use the Huawei EnVizion 360 (CV60) camera on an Apple silicon Mac.

### Added
- Live 360° view over USB-C (1920×960 or 1280×640, ~28 fps) with Flat, 360° and Little planet views.
  Drag to look around, scroll to zoom, double-click to reset.
- Mount setting that levels the picture when the camera is plugged sideways into a Mac.
- Full-resolution 5376×2688 photos taken by the camera, leveled and tagged as 360° photos (GPano),
  so Google Photos and Facebook show them as panoramas. The original camera JPEG is kept too.
- MP4 recording and live-view snapshots.
- Webcam for Zoom / Google Meet / Teams through OBS: the app publishes a "360 Webcam" Syphon feed
  that OBS sends out as "OBS Virtual Camera". Aim it in the Webcam preview window.
- Camera temperature warnings as macOS notifications; on overheat the camera is powered off.
- `cv60` command-line tool (inside the app bundle): info, raw H.264 dump, MP4 conversion, photo, power off.

### Notes
- Apple silicon only. The app is not notarized: on first launch open it via
  System Settings → Privacy & Security → "Open Anyway".
- Bundles libusb (LGPL-2.1) and Syphon (BSD); their licenses are in the app's Resources folder.
