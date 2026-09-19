# AGENTS.md — orientation for AI agents working on mob_background

You're in **mob_background**, a Mob capability plugin: keep the BEAM node alive when the screen locks or the app is backgrounded. iOS uses a silent `AVAudioEngine` session; Android uses a `dataSync` foreground service. Public API is `MobBackground.keep_alive/0` + `stop/0`.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules. This file is mob_background-specific.

> **Keep this file current.** When you change keep-alive behaviour, add a `host_requirements` entry, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_background is, in one paragraph

Continuous-execution keep-alive. `keep_alive/0` on iOS starts a silent `AVAudioEngine` loop with `AVAudioSessionCategoryOptionMixWithOthers` — the OS sees an active audio session and refuses to suspend the process; the user hears nothing; any music already playing is undisturbed. On Android the bridge starts `BeamForegroundService` (a `dataSync` foreground service that must display a persistent notification per Android policy). `stop/0` unwinds both. `keep_alive/0` is **idempotent** — safe to call multiple times.

## What mob_background is NOT

* **Not `mob_wake`.** mob_wake fires a specific handler on an OS event (scheduler firing or silent push) and returns. mob_background KEEPS RUNNING while the app is backgrounded. If your work is "wake, do one thing, sleep" → `mob_wake`. If it's "keep this GenServer / upload / walking tracker running" → this. They stack: activate both when both patterns apply.
* **Not a way to hide always-on servers on iOS.** Apple expects the declared background mode to match a user-visible app capability. `keep_alive/0` is legitimate for audio apps (music players, VoIP, radio); using it to hold a socket open on a chat app that has no audio feature is grounds for App Store rejection.
* **Not a replacement for push wake.** For server-initiated work, prefer push (mob_notify + mob_push, or silent-push via mob_wake). Background keep-alive is for continuous work the USER has kicked off in-app.

## Anatomy of the plugin

* `lib/mob_background.ex` — public `keep_alive/0` + `stop/0`.
* `src/mob_background_nif.erl` — Erlang NIF stub (tolerant `on_load`).
* `priv/mob_plugin.exs` — manifest. Bridge implements `MobActivityAware` (needs Activity Context). FOREGROUND_SERVICE permissions auto-merged; host `<service>` + iOS plist key declared as `host_requirements`.
* `priv/native/jni/mob_background_nif.zig` — Android NIF glue. Arity-0 static `CallStaticVoidMethod` to the bridge; no inbound delivery thunk, no pid.
* `priv/native/android/MobBackgroundBridge.kt` — starts/stops the foreground service. MobActivityAware (Activity Context).
* `priv/native/android/BeamForegroundService.kt` — the foreground `Service`. Ships in `priv/` because a foreground `<service>` must be a host-package class the build can't auto-inject; the host copies it into its own package.
* `priv/native/ios/mob_background_nif.m` — the silent `AVAudioEngine` session. Guards on `g_keep_alive_active` for idempotence.

## The two load-bearing invariants

1. **`keep_alive/0` is idempotent.** iOS guards on `g_keep_alive_active`; Android's service `onStartCommand` is safe to call repeatedly. Both restart the keep-alive after an interruption (iOS audio-session interruption → automatic engine restart; Android START_STICKY).
2. **The host requirements are real silent-failure landmines.** Without the Android `<service>` declaration `keep_alive/0` starts nothing; without iOS `UIBackgroundModes: [audio]` the silent session can't hold the app alive (and Apple rejects the mode for apps with no audio feature). The manifest declares both as `host_requirements` so every `mix mob.deploy --native` warns the host author. Keep that list accurate.

## Cross-repo work

**mob (framework):** `MobActivityAware` lives in mob core; the bridge implements it and depends on `MobPluginBootstrap.registerAll(this)` being called from the host's `MainActivity`. If that boot-registration contract changes, this plugin (and every other MobActivityAware plugin) has to move in lockstep.

**mob_new:** the host template ships `MainActivity.kt` with the `MobPluginBootstrap` call, and iOS `Info.plist.eex` with `UIBackgroundModes: [audio]`. Changes to either need matching updates here.

## Testing

Elixir suite:

```bash
mix test
```

Covers manifest structure and the API's idempotence rules on host (13 tests). Native code isn't exercised — deploy against a real device:

```bash
mix mob.deploy --native --device <serial>
```

Then call `MobBackground.keep_alive/0`, lock the screen, and confirm:
* **iOS:** BEAM keeps running (RPC via `mix mob.connect` still resolves; timers keep ticking).
* **Android:** persistent notification appears in the tray, BEAM keeps running.

## The pre-empt-failure rules that matter here

1. **Never call `keep_alive/0` unconditionally at boot.** Apple expects the entitlement to match a user-facing capability being exercised. Gate on the user action that justifies staying alive (music playing, upload in progress).
2. **Android's foreground notification is REQUIRED.** Trying to skip it because "it looks ugly" causes the service to be killed within seconds. The persistent-notification requirement is Google's policy, not this plugin's design.
3. **iOS audio-session interruption is handled but not silenced.** A phone call or Siri activation interrupts the silent session; the engine restarts automatically after. Do not assume `keep_alive/0` means "no interruptions ever" — the OS retains full control.
4. **Bridge `MobActivityAware` = needs Activity Context.** Boot-time registration only works via the host's `MobPluginBootstrap.registerAll(this)` call from `MainActivity.onCreate`. A missing registration is a silent failure — `keep_alive/0` returns but does nothing.

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

`mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). Sign the manifest against the shared mob key at `~/.mob/keys/` first. Do NOT bump versions without explicit permission. See `~/code/mob/RELEASE.md`.
