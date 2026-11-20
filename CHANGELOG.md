# Changelog

## [Unreleased]

### Added

- **`:media_playback` mode** for `start/1,2` (mode code `2` over the NIF), for
  apps that play audio the user hears. Same owner-bound session semantics as
  `:data_sync` (owner monitor, `START_NOT_STICKY`, action buttons,
  `{:mob_background, {:error, :foreground_refused}}`), and `status/0` reports
  `{:running, :media_playback}`.
  - **Android:** a `mediaPlayback` foreground service
    (`FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`, API 29+), with no Android 15
    background time limit, and an `ic_media_play` notification icon. The
    plugin doesn't declare the type or `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
    (Google Play asks every app to justify each type it declares): a host
    using `:media_playback` declares its own
    `<service android:name="io.mob.background.BeamForegroundService"
    android:foregroundServiceType="mediaPlayback">` (or
    `"dataSync|mediaPlayback"`) and the permission, and the build leaves that
    declaration alone. Without the type `start/2` returns
    `{:error, :unavailable}`.
  - **iOS:** the same silent `AVAudioEngine` keep-alive as `:data_sync`
    (`update/1` returns `:ok`, no UI); the NIF tracks the mode so `status/0`
    reports `{:running, :media_playback}`.
  - `MobBackground.SelfTest.classify/1` passes `{:running, :media_playback}`.
- Docs: *Choosing the type*, and how a host whose own `<service>` doesn't use
  `microphone` drops the plugin's `FOREGROUND_SERVICE_MICROPHONE` with
  `tools:node="remove"` (the build skips a plugin permission the host
  manifest already names). This answers 0.3.0's *Upgrading* note: an app with
  no microphone feature no longer has to stay on 0.2.x.

### Fixed

- **Android `status/0` for hosts whose `<service>` declares only
  `mediaPlayback` (or only `microphone`)** no longer reports
  `{:error, :service_not_data_sync}` (and the self-test no longer fails).
  That error, which keeps its name, now means the `<service>` declares none of
  `dataSync`, `microphone`, `mediaPlayback`.

`:data_sync`, `:microphone`, and `keep_alive/0` start, run, and return as in
0.3.0; only the `status/0` fix above touches them. In a host whose
`<service>` lacks `dataSync`, `keep_alive/0` still logs a warning and starts
nothing, and `status/0` no longer flags it.

## [0.3.0] - 2026-11-19

### Added

- **Typed, owner-bound foreground service (`start/1,2`, `update/1`) and
  `:microphone` mode.** Generalizes `mob_background` beyond `keep_alive/0` so
  apps can start a foreground service in `:data_sync` or `:microphone` mode
  bound to an `owner` process with a custom notification title, text, and up to
  3 action buttons:
  - Button taps deliver `{:mob_background, {:action, id}}` to the owner (using
    `enif_make_existing_atom_len` — never creating atoms from Java input). If
    a tap cannot be delivered to an owner (owner-less session or exited
    owner/BEAM), the Android service stops itself and the NIF clears running
    state so both sides stay synchronized.
  - Owner exit (via ERTS process monitor + generation counter) automatically
    stops the service on both Android and iOS without calling JNI from the
    monitor callback.
  - Asynchronous `startForeground` refusals (Android 14+ while-in-use rules)
    and Android 15 `onTimeout` events deliver
    `{:mob_background, {:error, :foreground_refused}}` and
    `{:mob_background, {:error, :timeout}}` to the owner and clear running
    state.
  - `update/1` skips unchanged notifications in Zig and coalesces Android
    notification posts to at most once every 250 ms while live; on iOS,
    `update/1` returns `:ok` while running (no persistent notification surface;
    `:microphone` mode returns `{:error, :unsupported}`).
  - `keep_alive/0` and `stop/0` keep working unchanged (`keep_alive/0` starts
    an owner-less `:data_sync` session when idle and is a no-op if any session
    is running).
- **Android manifest permissions & service type:** adds
  `android.permission.FOREGROUND_SERVICE_MICROPHONE` to `priv/mob_plugin.exs`
  and updates the contributed `<service>` snippet to
  `android:foregroundServiceType="dataSync|microphone"`. (`RECORD_AUDIO`
  remains the host app's responsibility.)

### Upgrading

- **Every host that activates the plugin now declares the microphone
  foreground-service type and `FOREGROUND_SERVICE_MICROPHONE`**, including apps
  that only call `keep_alive/0`. On Google Play that means completing the
  foreground-service declaration for microphone use in the Play Console; an app
  with no microphone feature can be rejected for it. Such apps should stay on
  0.2.x until the service type can be chosen per host.
- Update the dependency to `{:mob_background, "~> 0.3"}`; `start/1,2` and
  `update/1` don't exist in 0.2.

### Changed

- **Breaking:** `MobBackground.status/0` (and `background_status/0`) now
  returns `{:running, :data_sync}` or `{:running, :microphone}` instead of bare
  `:running`. Callers pattern-matching `:running` must update to
  `{:running, _}` (or `{:running, mode}`). `MobBackground.SelfTest.classify/1`
  now passes `:idle`, `{:running, :data_sync}`, and `{:running, :microphone}`
  and treats bare `:running` as unexpected.

### Fixed

- **Fixed: MOB-505 — `BeamForegroundService` no longer uses androidx
  `ServiceCompat`** (which needs `androidx.core` 1.12; Mob hosts use 1.9),
  using platform `startForeground`/`stopForeground` instead.

## [0.2.0] - 2026-10-09

### Fixed

- **Android: an unmodified host now compiles and gets a working keep-alive**
  (MOB-423). `MobBackgroundBridge.kt` referenced
  `io.mob.background.BeamForegroundService`, but the build copied only the
  bridge, so a fresh `mix mob.new` host failed with `Unresolved reference`
  until the author copied the service in by hand. `android.bridge_kt` now
  lists both files, so the build copies `BeamForegroundService.kt` into
  `io/mob/background/` next to the bridge, and the manifest contributes
  `<service android:name="io.mob.background.BeamForegroundService"
  android:exported="false" android:foregroundServiceType="dataSync" />`
  through `android.manifest_application_snippets` (skipped when the host
  already declares it). The two Android `host_requirements` are gone.
  **Hosts that copied `BeamForegroundService.kt` by hand must delete their
  copy** (one at `io/mob/background/` is overwritten; one elsewhere would
  clash), and can drop their hand-added `<service>` entry.

### Added

- **On-device self-test** (MOB-418). `MobBackground.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls the new read-only `background_status/0` NIF, which never starts the
  keep-alive: `:idle` / `:running` pass; the iOS NIF answers
  `{:error, :no_audio_background_mode}` without `UIBackgroundModes` `audio`,
  and the Android NIF answers `{:error, :bridge_not_registered}`,
  `:no_activity`, `:service_not_declared` or `:service_not_data_sync`; all
  fail, as does a NIF that isn't linked. Run it with `mix mob.selftest` from
  a host app (mob_dev 0.7.17).
- **`MobBackground.status/0`**, the public face of `background_status/0`:
  reports `:idle`, `:running` or `{:error, reason}` without starting the
  keep-alive.

### Changed

- **Requires mob >= 0.9.15** (was `~> 0.7`), for `Mob.Plugin.SelfTest`;
  `mob_version` in the manifest is now `~> 0.9` (was `~> 0.6`). Hosts on
  mob 0.7 or 0.8 must upgrade mob before taking this release.

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
