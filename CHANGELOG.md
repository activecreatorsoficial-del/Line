# Changelog

## 0.9.0 — 2026-11-08

First public open-source preview under the MIT license.

### Added

- Internet invitation and response exchange using encrypted WebRTC connection descriptions.
- Free public STUN discovery to help devices find a direct connection across networks.
- Sender and receiver guidance for returning the connection response, with separate 12-digit Internet codes.
- Windows installer, portable Windows package and Android preview APK.

### Included from earlier previews

- Nearby rooms for devices on the same local network with eight-digit temporary codes.
- Chunked file streaming, progress on both devices and SHA-256 verification before completing a received file.
- Monochrome Active Creators interface, responsive layouts, motion and the two-arrow Line icon.
- Android foreground sharing sessions and bounded, repeatable cancellation after connection errors.

### Preview limitations

Direct Internet connections depend on a usable route through the participating networks. The app has no default relay fallback. Transfers between unrelated physical Internet connections remain unverified in the recorded release tests. Multi-gigabyte performance and production release signing remain future work.
