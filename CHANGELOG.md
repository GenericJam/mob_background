# Changelog

## 0.1.0

Initial release. Background execution keep-alive, extracted from mob core into
an opt-in plugin:

- `MobBackground.keep_alive/0` / `MobBackground.stop/0`.
- **iOS:** a silent `AVAudioEngine` session (`MixWithOthers`) so the OS keeps
  the app running when the screen locks; auto-restarts after audio-session
  interruptions (recording, phone calls).
- **Android:** a `dataSync` foreground service (`BeamForegroundService`) with a
  low-priority persistent notification.

Two host requirements the native build warns about: an Android `<service>`
declaration (the service source ships under
`priv/native/android/BeamForegroundService.kt`) and the iOS
`UIBackgroundModes: [audio]` plist key.
