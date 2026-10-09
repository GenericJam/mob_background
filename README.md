# mob_background

Background execution keep-alive for [Mob](https://github.com/GenericJam/mob)
apps — keep the BEAM node running when the screen locks or the app is
backgrounded.

- **iOS:** a silent `AVAudioEngine` session (`MixWithOthers`) so the OS keeps
  the app alive. The user hears nothing; any music already playing is
  undisturbed.
- **Android:** a `dataSync` foreground service with a low-priority persistent
  notification. The OS won't kill it under memory pressure or when the screen
  locks.

## Usage

```elixir
# Keep the app alive when the screen locks (e.g. in mount/2):
MobBackground.keep_alive()

# Allow suspension again when no longer needed:
MobBackground.stop()
```

`keep_alive/0` is idempotent — safe to call multiple times. `status/0` reports,
without changing anything, whether keep-alive can work in this host and whether
it's on.

Run `mix mob.selftest` from a host app to check on a device that the native
side is linked and wired up (`MobBackground.SelfTest`, a read-only
`background_status/0` call that never starts the keep-alive).

## Install

```elixir
# mix.exs
{:mob_background, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_background]
config :mob, :trusted_plugins, %{mob_background: "ed25519:<fingerprint>"}
```

`mix mob.plugin.trust mob_background` records the fingerprint, then
`mix mob.deploy --native`.

## Host requirements (the native build warns about these)

On Android the build adds everything when the plugin is activated: the
`FOREGROUND_SERVICE` permissions, the `BeamForegroundService` class (copied
into `io/mob/background/` next to the bridge) and its `<service
android:foregroundServiceType="dataSync">` declaration. If you copied
`BeamForegroundService.kt` into your app for plugin 0.1.x somewhere other
than `io/mob/background/`, delete that copy.

This one can't be added by the build, so it prints as a warning on every
`mix mob.deploy --native` of the host:

- **iOS `UIBackgroundModes`.** `Info.plist` must declare the `audio` mode (the
  keep-alive uses a silent audio session). `mix mob.new` adds this; for Xcode
  projects use *Signing & Capabilities → Background Modes → Audio, AirPlay, and
  Picture in Picture*. Apple rejects this mode for apps with no audio feature —
  only use this plugin in apps that legitimately use audio.

## Notes

- **Coexistence with Mob.Audio:** playback mixes transparently (both use
  `MixWithOthers`); recording temporarily takes the audio session, and the
  keep-alive engine restarts automatically when recording (or a phone call)
  ends.
- **Android notification:** Android requires every foreground service to post a
  visible notification ("Running in background", `IMPORTANCE_LOW`, no sound).
  There is no API to hide it.
- **Android 15 time limit:** with `targetSdk` 35+, Android allows a `dataSync`
  foreground service at most 6 hours per 24 hours while the app is in the
  background. When the limit is hit the service stops itself (logged under the
  `MobBackground` tag) and the notification disappears; the BEAM is not told.
  Call `keep_alive/0` again once the app returns to the foreground.

## License

MIT.
