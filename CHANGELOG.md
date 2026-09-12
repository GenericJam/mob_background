# Changelog

## [Unreleased]

### Fixed

- **Android: JNI exception no longer leaks onto the BEAM scheduler thread**
  (MOB-59). `Java_..._nativeRegister` now clears any pending
  `NoSuchMethodError` after a `getStaticMethodID` returns `null` (matches
  the pattern in mob core's `mob_ui_cache_class`). Both runtime NIFs
  (`background_keep_alive`, `background_stop`) call `jni.exceptionClear`
  after their `CallStaticVoidMethod`, so a Kotlin-side exception
  (`SecurityException` from a missing `FOREGROUND_SERVICE` permission,
  `IllegalStateException` from a foreground-service start restriction on
  Android 12+, etc.) cannot linger on the JNIEnv and cause the next JNI
  call on the same scheduler thread to crash. The runtime NIFs also now
  guard on a missing bridge cache — a host that never called
  `MobPluginBootstrap.registerAll(this)` gets a silent no-op instead of
  passing a null `jclass` to `CallStaticVoidMethod`, which itself was UB.
  The `:ok` return contract from `MobBackground.keep_alive/0` and
  `stop/0` is unchanged. iOS path is untouched.

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
