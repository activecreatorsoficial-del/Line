# Contributing to Line

Thanks for helping improve direct file sharing between Windows and Android.

## Report a problem

Open an issue with the Line version, operating systems, selected sharing mode and steps to reproduce it. For connection problems, explain whether the devices use the same Wi-Fi, separate home networks or mobile data. Include the exact error message and redact network addresses from screenshots.

Keep live invitations, responses, temporary codes, private files and credentials private. Use private vulnerability reporting for security-sensitive findings, as described in SECURITY.md.

## Work on the app

1. Fork the repository and create a branch for one change.
2. Install Flutter 3.47.1 with Dart 3.13.1 and follow the development guide.
3. Keep the change focused and preserve Windows and Android behavior.
4. Run the existing checks and add a regression test when fixing behavior that they do not cover.
5. Open a pull request describing the problem, resulting behavior and verification. Include screenshots for visible UI changes.

```sh
flutter pub get
flutter analyze
flutter test
```

Visual golden images were recorded on Windows. Run visual checks there before updating their reference images. Native networking tests need their target platform and are separate from the unit and widget suite. Build Flutter targets sequentially.

Implementation details and native test commands are in the development guide. [Development guide](docs/DEVELOPMENT.md)

## Contribution license

By submitting a contribution, you agree to license your original contribution under the project's MIT license. Keep existing third-party copyright and license notices with reused material.
