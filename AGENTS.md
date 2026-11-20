# mob_background — Agent Instructions

You're in **mob_background**, a Mob capability plugin: keep the BEAM node alive when the screen locks or the app is backgrounded. iOS uses a silent `AVAudioEngine` session (`:data_sync` and `:media_playback`; `:microphone` returns `{:error, :unsupported}`); Android uses a typed foreground service (`dataSync`, `microphone`, or host-declared `mediaPlayback`) with dynamic notifications and action buttons. Public API is `MobBackground.start/1,2`, `update/1`, `stop/0`, `keep_alive/0`, and `status/0`. Extracted from mob core into an opt-in plugin.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules. This file is mob_background-specific.

> **Keep this file current.** When you change keep-alive behaviour, add a `host_requirements` entry, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_background is, in one paragraph

Continuous-execution keep-alive. `start/1,2` starts (or retargets) an owner-bound background session in `:data_sync` (mode `0`), `:microphone` (mode `1`), or `:media_playback` (mode `2`) mode with a notification title, text, and up to 3 action buttons (`update/1` updates it live; owner death stops it; button taps arrive at the owner as `{:mob_background, {:action, id}}`). `keep_alive/0` is the legacy owner-less `:data_sync` shortcut (idempotent; no-op if any session is already running). On iOS `:data_sync` and `:media_playback` run the same silent `AVAudioEngine` loop with `AVAudioSessionCategoryOptionMixWithOthers` (no notification UI; the NIF tracks the mode only for `status/0`; `:microphone` returns `{:error, :unsupported}`). On Android `MobBackgroundBridge` drives `BeamForegroundService` (channel `"mob_background"` at `IMPORTANCE_DEFAULT` without sound/vibration for `start/2` so buttons stay visible; `"mob_beam_fg"` at `IMPORTANCE_LOW` for `keep_alive/0`). The plugin's `<service>` snippet declares only `dataSync|microphone`; `:media_playback` needs the host's own `<service>` with `mediaPlayback` plus `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (the build leaves a host declaration alone; Play asks each app to justify every type), else `start/2` returns `{:error, :unavailable}`. `stop/0` unwinds both.

## What mob_background is NOT

* **Not `mob_wake`.** mob_wake fires a specific handler on an OS event (scheduler firing or silent push) and returns. mob_background KEEPS RUNNING while the app is backgrounded. If your work is "wake, do one thing, sleep" → `mob_wake`. If it's "keep this GenServer / upload / walking tracker / audio monitor running" → this. They stack: activate both when both patterns apply.
* **Not a way to hide always-on servers on iOS.** Apple expects the declared background mode to match a user-visible app capability. `keep_alive/0` / `start/2` is legitimate for audio apps (music players, VoIP, radio); using it to hold a socket open on a chat app that has no audio feature is grounds for App Store rejection.
* **Not a replacement for push wake.** For server-initiated work, prefer push (mob_notify + mob_push, or silent-push via mob_wake). Background keep-alive is for continuous work the USER has kicked off in-app.

## Anatomy of the plugin

* `lib/mob_background.ex` — public `start/1,2`, `update/1`, `stop/0`, `keep_alive/0`, `status/0`, pure validation helpers `nif_args/2` and `notification_nif_args/1`.
* `lib/mob_background/self_test.ex` — `MobBackground.SelfTest` (`Mob.Plugin.SelfTest`, run by `mix mob.selftest`): classifies `background_status/0` (`:idle` and `{:running, :data_sync | :microphone | :media_playback}` pass; bare `:running` fails). Never starts the service.
* `src/mob_background_nif.erl` — Erlang NIF stub exporting `background_keep_alive/0`, `background_stop/0`, `background_status/0`, `background_start/5`, `background_update/3` (tolerant `on_load`).
* `priv/mob_plugin.exs` — manifest. Bridge implements `MobActivityAware` (needs Activity Context). `android.bridge_kt` lists `MobBackgroundBridge.kt` and `BeamForegroundService.kt` (copied into `io/mob/background/`). Contributes `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and `FOREGROUND_SERVICE_MICROPHONE` (NOT `RECORD_AUDIO`), and `<service ... android:foregroundServiceType="dataSync|microphone" />`. Only the iOS `UIBackgroundModes: [audio]` plist key is a `host_requirement`.
* `priv/native/jni/mob_background_nif.zig` — Android NIF glue (`ERL_NIF_DIRTY_JOB_IO_BOUND` for `start`/`update`/`stop`/`keep_alive`). Caches bridge + `java/lang/String` jclasses and all 5 static method IDs in `nativeRegister` (runs before `nifLoad`); guards shared state (`running`, `mode`, `owner`, `generation`, `watch` monitor resource, stored last notice for unchanged-update skip) with an `enif_mutex`. Sends `{:mob_background, {:action, id}}` (via `enif_make_existing_atom_len` — never creating atoms from Java input) and `{:mob_background, {:error, :foreground_refused | :timeout}}` from `nativeAction` / `nativeFailed`. Encodes all strings to Java as UTF-16 via `NewString` (emoji-safe) and decodes action IDs from UTF-16 via `GetStringChars`.
* `priv/native/android/MobBackgroundBridge.kt` — `MobActivityAware` singleton owning the `pendingStarts`/`stopWanted`/`live` race lock, manifest & `RECORD_AUDIO` checks, 250 ms main-thread notification coalescing, channels (`mob_beam_fg` vs `mob_background`), and `PendingIntent` action buttons. `background_stop()` reads thread-safe `appContext ?: activityRef?.get()` (never the main-thread-only `service` reference).
* `priv/native/android/BeamForegroundService.kt` — typed foreground `Service` (`dataSync` / `microphone` / `mediaPlayback`) using platform `startForeground`/`stopForeground` directly (no `ServiceCompat`, MOB-505). Handles `ACTION_BUTTON` taps, `startForeground` failures (`nativeFailed("foreground_refused")`), API 34/35 `onTimeout` (`nativeFailed("timeout")`), `START_NOT_STICKY` for `start/1,2` owner sessions vs `START_STICKY` for owner-less `keep_alive/0`, and cancels `NOTIFICATION_ID` in `onDestroy`.
* `priv/native/ios/mob_background_nif.m` — silent `AVAudioEngine` keep-alive guarded by `g_bg_lock` (`pthread_mutex_t`) + `g_watch_type` owner monitor (`enif_open_resource_type_x` in `nif_load`). `:microphone` returns `{:error, :unsupported}`; `:data_sync` and `:media_playback` share the session, and `status/0` returns `{:running, :data_sync | :media_playback}` (from `g_bg.mode`) when active.

## Load-bearing invariants

1. **Android `startForegroundService` / `stopService` race protocol.** Calling `stopService` after `startForegroundService` but before `BeamForegroundService.onStartCommand` calls `startForeground` crashes Android (`did not then call Service.startForeground()`). `MobBackgroundBridge` tracks `pendingStarts` and `stopWanted` under `lock`: `background_stop()` sets `live = false` and, if `pendingStarts > 0`, sets `stopWanted = true` instead of calling `stopService`. `onStartCommand` calls `startForeground(...)`, then `foregrounded()` decrements `pendingStarts` and returns `true` when `stopWanted && pendingStarts == 0` so the service stops itself safely right after reaching the foreground.
2. **Owner monitor + generation counter.** `bg_watch_locked` allocates a `mob_background_owner` resource stamped with the current `generation` (bumped on every start, stop, or failure) and monitors `owner`. An ERTS `down` callback must NEVER call JNI or block on AVFoundation: Zig's `bgOwnerDown` spawns a detached pthread (`jni.pthread_create` + `jni.pthread_detach`) which acquires `g_bg_lock` and stops the service only if `running && has_owner && generation == g_bg.generation`; iOS `bg_owner_down` checks the generation under `g_bg_lock` and dispatches the audio stop onto the main queue.
3. **Action button safety.** Action IDs are validated in Elixir (non-`nil`/non-boolean/non-empty atom, `<= 255` UTF-8 bytes) and looked up on Android via `enif_make_existing_atom_len` so Java input can never allocate atoms. Whenever `nativeAction` returns `false` (no owner listening — e.g. owner exited or `keep_alive/0` updated with buttons — or bad/unknown ID), it also clears Zig's running state (`running = false`, `last.valid = false`, `bgForgetLocked()`) in lockstep with `BeamForegroundService` stopping itself so the notification never outlives its owner and `status`/`keep_alive`/`update` stay synchronized. `onDestroy` cancels `NOTIFICATION_ID` so a delayed coalesced `nm.notify` post cannot leave a dead ongoing notification.
4. **Owner-bound `start/1,2` vs owner-less `keep_alive/0`.** `start/1,2` (`background_start/5`) always requires a local `pid` and runs `START_NOT_STICKY` on Android; `keep_alive/0` (`background_keep_alive/0`) is the sole owner-less (`START_STICKY`) entry point. `background_stop()` runs on dirty IO schedulers and must only read thread-safe refs (`appContext ?: activityRef?.get()`), never the main-thread-only `service` field.
5. **No `androidx.core.app.ServiceCompat` (MOB-505).** Mob hosts compile against `androidx.core` 1.9, while `ServiceCompat.startForeground` / `stopForeground` need 1.12+. Keep using platform `Service.startForeground` (with `SDK_INT >= 30` for `FOREGROUND_SERVICE_TYPE_MICROPHONE`, `>= 29` for `FOREGROUND_SERVICE_TYPE_DATA_SYNC` / `FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`) and `Service.stopForeground(STOP_FOREGROUND_REMOVE)` (`>= 24`). `test/mob_background_test.exs` enforces this.
6. **`keep_alive/0` compatibility & `status/0` contract.** `keep_alive/0` is idempotent: starts an owner-less `data_sync` session when idle, swallows errors (logged on Android), and is a no-op `:ok` if any session is already running (never overrides an owner session). `status/0` returns `{:running, :data_sync | :microphone | :media_playback}` when running (never bare `:running`). Android status code `7` = running media_playback; `{:error, :service_not_data_sync}` (code `4`, name kept for compatibility) means the `<service>` declares none of `dataSync`, `microphone`, `mediaPlayback`.
7. **The host requirements are real silent-failure landmines.** Without the Android `<service>` declaration `keep_alive/0` and `start/2` cannot start the service; without `RECORD_AUDIO` granted at runtime `:microphone` returns `{:error, :permission}`; without iOS `UIBackgroundModes: [audio]` the silent session can't hold the app alive (and Apple rejects the mode for apps with no audio feature). `RECORD_AUDIO` stays out of plugin permissions (hosts using `:microphone` declare/request it; `mob_new` hosts already declare it). `mediaPlayback` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` also stay out (host-declared). `UIBackgroundModes: [audio]` stays a `host_requirement`. `status/0` and `SelfTest` report missing host wiring: no `<service>`, or one with none of `dataSync`/`microphone`/`mediaPlayback`. A host `<service>` lacking just `dataSync` passes them, and there `keep_alive/0` only logs a warning (tag `MobBackground`) and starts nothing.

## Cross-repo work

**mob (framework):** `MobActivityAware` lives in mob core; the bridge implements it and depends on `MobPluginBootstrap.registerAll(this)` being called from the host's `MainActivity`. Also note `nativeRegister` runs from `MainActivity.onCreate` BEFORE `:mob_background_nif` runs `nifLoad`, so `nativeRegister` must never rely on resources/mutexes created in `nifLoad`.

**mob_new:** the host template ships `MainActivity.kt` with the `MobPluginBootstrap` call, Android `RECORD_AUDIO` in `AndroidManifest.xml.eex`, and iOS `Info.plist.eex` with `UIBackgroundModes: [audio]`. Changes to those need matching updates here.

## Testing

Elixir suite:

```bash
mix test
```

Covers:
- Manifest structure, permissions (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `FOREGROUND_SERVICE_MICROPHONE`, absence of `RECORD_AUDIO`), `host_requirements`, `SelfTest` wiring.
- Android Kotlin structural checks (`io.mob.background` package, `::class` resolution, `<service>` snippet `foregroundServiceType="dataSync|microphone"` matching `FOREGROUND_SERVICE_TYPE_DATA_SYNC` / `FOREGROUND_SERVICE_TYPE_MICROPHONE`, and no `ServiceCompat` reference for MOB-505).
- NIF stub agreement (`background_keep_alive/0`, `background_stop/0`, `background_status/0`, `background_start/5`, `background_update/3`) and `MobBackground` exports (`keep_alive/0`, `stop/0`, `status/0`, `start/1`, `start/2`, `update/1`).
- Pure validation helpers `MobBackground.nif_args/2` and `MobBackground.notification_nif_args/1` (defaults, mode mapping, action normalization, emoji round-trip, and every `ArgumentError` validation rule).
- `MobBackground.SelfTest.classify/1` (`:idle`, `{:running, :data_sync}`, `{:running, :microphone}`, `{:running, :media_playback}` pass; bare `:running`, host errors, and unexpected values fail).

Native code isn't exercised by `mix test` — `mix mob.selftest` from a host app runs the self-test on a device; for full keep-alive and `:microphone` foreground service verification deploy against a real device:

```bash
mix mob.deploy --native --device <serial>
```

Then verify both `MobBackground.keep_alive/0` and `MobBackground.start(mode: :microphone, notification: ...)` on hardware (including action button taps, owner process exit, background start refusal on Android 14+, and iOS `{:error, :unsupported}` for `:microphone` / owner exit for `:data_sync`).

## The pre-empt-failure rules that matter here

1. **Never call `keep_alive/0` or `start/2` unconditionally at boot.** Apple expects `UIBackgroundModes: [audio]` to match an active user-facing capability, and Android 14+ requires foreground context for `microphone` services.
2. **Android's foreground notification is REQUIRED.** Trying to hide it causes Android to kill the service within seconds.
3. **iOS audio-session interruption is handled but not silenced.** A phone call, Siri activation, or `Mob.Audio` recording interrupts the silent session; the engine restarts automatically when the interruption ends.
4. **Bridge `MobActivityAware` = needs Activity Context.** Boot-time registration only works via the host's `MobPluginBootstrap.registerAll(this)` call from `MainActivity.onCreate`.

## Pre-commit + release

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin   # from a host app
```

Native code isn't exercised by `mix test`; verify on a device (see Testing).

Release: `mix.exs` version is the source of truth, and a bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). Do NOT bump versions without explicit permission. See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). Steps:

1. Bump the version and update `CHANGELOG.md`.
2. Sign the manifest with the shared mob key at `~/.mob/keys/`: `cp ~/.mob/keys/<sibling>.priv ~/.mob/keys/mob_background.priv && mix mob.plugin.sign`.
3. Publish: the GitHub release workflow on push, or `HEX_API_KEY=… mix hex.publish` with `~/.hex/hex.config` moved aside.

A published version is permanent — get a native build green on hardware first.
