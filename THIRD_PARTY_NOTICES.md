# Third-party notices

Line's original source code is available under the MIT license in LICENSE. Its dependencies and bundled third-party assets retain their own licenses.

## Inter

The Inter font is bundled in assets/fonts/Inter.ttf under the SIL Open Font License 1.1. The complete copyright and license notice accompanies it. [Inter license](assets/fonts/OFL.txt)

## Flutter and Material icons

Flutter is distributed under the BSD 3-Clause license. A copy from the recorded Flutter SDK accompanies this source tree. [Flutter license](assets/licenses/Flutter-LICENSE.txt)

The Material Icons font distributed with the recorded Flutter 3.47.1 SDK carries the Creative Commons Attribution 4.0 International license. Material Icons are by Google. Line's generated app icons use its swap_horiz_rounded glyph, rendered at multiple sizes in white on a dark rounded square. These derived icon assets retain that attribution and license. The font's supplied notice is preserved in full. [Material Icons](https://fonts.google.com/icons), [supplied font license](assets/licenses/MaterialIcons-LICENSE.txt)

## Dependencies

pubspec.yaml declares the direct Flutter packages and pubspec.lock records the resolved versions. Each package includes its upstream license through the Dart package distribution. flutter_webrtc also uses native WebRTC components and their third-party notices. Follow these notices when redistributing a modified application.

The legacy Node reference in server/ uses ws under its upstream MIT license. tools/licenses/ preserves the Node distribution notice used by older packages. Current native app packages use the Flutter runtime.
