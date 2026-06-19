# mob_background — Agent Instructions

A Mob capability plugin: keep the BEAM node alive when the screen locks or the
app is backgrounded. iOS uses a silent `AVAudioEngine` session; Android uses a
`dataSync` foreground service. Extracted from mob core into an opt-in plugin.

## Layout

- `lib/mob_background.ex` — the public `keep_alive/0` / `stop/0` API.
- `src/mob_background_nif.erl` — the Erlang NIF stub (tolerant `on_load`).
- `priv/mob_plugin.exs` — the manifest (the bridge implements `MobActivityAware`;
  FOREGROUND_SERVICE permissions auto-merged; the host `<service>` + iOS plist
  key are declared as `host_requirements`).
- `priv/native/jni/mob_background_nif.zig` — Android NIF glue (arity-0 static
  `CallStaticVoidMethod` to the bridge; no inbound delivery thunk, no pid).
- `priv/native/android/MobBackgroundBridge.kt` — starts/stops the foreground
  service (`MobActivityAware`, needs the Activity Context).
- `priv/native/android/BeamForegroundService.kt` — the foreground `Service`.
  Ships in `priv/` because a foreground `<service>` must be a host-package class
  the build can't auto-inject; the host copies it into its own package.
- `priv/native/ios/mob_background_nif.m` — the silent `AVAudioEngine` session.

## The two load-bearing invariants

1. **`keep_alive/0` is idempotent.** iOS guards on `g_keep_alive_active`;
   Android's service `onStartCommand` is safe to call repeatedly. Both restart
   the keep-alive after an interruption (iOS audio-session interruption →
   automatic engine restart; Android START_STICKY).
2. **The host requirements are real silent-failure landmines.** Without the
   Android `<service>` declaration `keep_alive/0` starts nothing; without iOS
   `UIBackgroundModes: [audio]` the silent session can't hold the app alive (and
   Apple rejects the mode for apps with no audio feature). The manifest declares
   both as `host_requirements` so every `mix mob.deploy --native` warns the host
   author. Keep that list accurate.

The bridge implements `MobActivityAware` (it needs the Activity Context), so it
depends on the host's `MainActivity` calling
`MobPluginBootstrap.registerAll(this)`.

## Pre-commit checklist

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
zig fmt priv/native/jni/*.zig
xcrun clang-format -i priv/native/ios/*.m
mix mob.validate_plugin   # from a host app
```

Native code isn't exercised by `mix test`; verify on a device (`mix mob.deploy
--native`, call `MobBackground.keep_alive/0`, lock the screen, confirm the BEAM
keeps running — and on Android confirm the persistent notification appears).

## Release

`mix.exs` version is the source of truth. Bump it, update `CHANGELOG.md`, sign
with the shared mob key (`cp ~/.mob/keys/<sibling>.priv ~/.mob/keys/mob_background.priv
&& mix mob.plugin.sign`), then publish (GitHub release workflow on push, or
`HEX_API_KEY=… mix hex.publish` with `~/.hex/hex.config` moved aside). A published
version is permanent — get a native build green on hardware first.
