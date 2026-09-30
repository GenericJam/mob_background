# Changelog

## [0.1.2] - 2026-09-30

### Fixed

- **Android: no crash when the Android 15 `dataSync` time limit expires**
  (MOB-307). With targetSdk 35, dataSync foreground services get at most 6h
  per 24h in the background; `BeamForegroundService` had no `onTimeout`, so
  the system crashed the app with `ForegroundServiceDidNotStopInTimeException`.
  It now implements `onTimeout` (API 34 and 35 overloads), logs a warning under
  the `MobBackground` tag, and stops the service. The BEAM is not notified;
  call `keep_alive/0` again from the foreground. Hosts that copied
  `BeamForegroundService.kt` must re-copy it.

### Changed

- **Android: foreground service type is now passed explicitly** (MOB-299).
  `BeamForegroundService` uses `ServiceCompat.startForeground` with
  `FOREGROUND_SERVICE_TYPE_DATA_SYNC` (and `ServiceCompat.stopForeground`)
  instead of the two-argument `startForeground`. No behaviour change: the
  old call already resolved to the manifest's `dataSync` type (dumpsys shows
  `types=0x00000001` either way). The logcat line
  `ForegroundServiceTypeLoggerModule: ... does not have any types` that
  prompted this is AOSP stats-logger noise printed for every `dataSync`
  service and still appears; it is harmless.

## [0.1.1] - 2026-09-30

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
  `keep_alive/0` and `stop/0` now always return `:ok`, matching their
  `@spec`. Previously a `get_jenv` failure returned `:error`. Note that a
  Kotlin-side failure is swallowed: the keep-alive simply doesn't start,
  and nothing is returned or logged. iOS path is untouched.

- **Package now ships `priv/mob_plugin.pub`** (MOB-65). 0.1.0 was
  published signed but without its public key, so
  `mix mob.plugin.trust mob_background` failed with "ships no
  priv/mob_plugin.pub" and the host signature gate could not verify the
  plugin. The shared Mob first-party key (same fingerprint as
  `mob_camera` / `mob_ash` / `mob_audio_capture`) is now included.

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
- **Docs: "Which plugin do I actually want?" section** in the
  `MobBackground` moduledoc. It explains how `mob_background` (continuous
  keep-alive) differs from `mob_wake` (OS-triggered handler), `mob_notify`
  (local notifications and push registration) and `mob_push` (server-side
  send).
- **Docs: the keep-alive notification needs `POST_NOTIFICATIONS` to be
  visible on Android 13+.** The `keep_alive/0` docs said the notification
  always appears in the status bar; on API 33+ it's only shown when the app
  holds `POST_NOTIFICATIONS`. The foreground service itself runs either way
  (device-verified on a Moto G Power 5G 2024, Android 15).

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
