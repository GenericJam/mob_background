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

`keep_alive/0` is idempotent — safe to call multiple times.

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

These can't be auto-injected, so they print as a warning on every
`mix mob.deploy --native` of the host:

- **Android `<service>`.** A foreground service must be a host-package class.
  Add to `AndroidManifest.xml` inside `<application>`:

  ```xml
  <service android:name="io.mob.background.BeamForegroundService"
      android:exported="false"
      android:foregroundServiceType="dataSync" />
  ```

  The service source ships in this package under
  `priv/native/android/BeamForegroundService.kt` — copy it into your host
  package (the build copies only the bridge automatically). The
  `FOREGROUND_SERVICE` permissions are added automatically on activation.

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

## License

MIT.
