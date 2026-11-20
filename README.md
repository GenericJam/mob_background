# mob_background

Background execution keep-alive and typed foreground service for
[Mob](https://github.com/GenericJam/mob) apps — keep the BEAM node running when
the screen locks or another app is in front.

- **iOS:** a silent `AVAudioEngine` session (`MixWithOthers`) for `:data_sync`
  and `:media_playback` keep-alive. The user hears nothing; any music already
  playing is undisturbed. Mode `:microphone` returns `{:error, :unsupported}`
  (see *Modes* below).
- **Android:** `BeamForegroundService`, a typed foreground service (`dataSync`,
  `microphone`, or `mediaPlayback`) with either a low-priority default
  notification (`keep_alive/0`) or an owner-bound dynamic notification with
  action buttons (`start/1,2` + `update/1`).

## Usage

### Typed, owner-bound session (`start/1,2` + `update/1`)

Use `start/1,2` when you need `:microphone` or `:media_playback` mode, custom
notification text, or interactive notification buttons:

```elixir
:ok =
  MobBackground.start(self(),
    mode: :microphone,
    notification: %{
      title: "Listening",
      text: "A4 −12¢",
      actions: [
        %{id: :pause, label: "Pause"},
        %{id: :stop, label: "Stop"}
      ]
    }
  )

# Update title, text, or buttons (at most ~4 posts/s on Android; unchanged
# updates skip JNI completely):
:ok =
  MobBackground.update(%{
    title: "Paused",
    text: "Tap Resume to continue",
    actions: [
      %{id: :resume, label: "Resume"},
      %{id: :stop, label: "Stop"}
    ]
  })

:ok = MobBackground.stop()
```

### Messages sent to the owner process

`start/2` monitors `owner` (`self()` by default in `start/1`). If the owner
process exits, the native layer stops the service and removes the notification
automatically. While running, `owner` receives:

- `{:mob_background, {:action, id}}` — user tapped notification action button
  `id` (the atom from `actions`). Action taps do not stop or mutate the
  service on their own; handle the message and call `update/1` or `stop/0`. If
  a tap cannot be delivered to an owner (for example, an owner-less
  `keep_alive/0` session updated with buttons, or an exited owner/BEAM), the
  Android service stops itself and the native layer ends the session on both
  sides.
- `{:mob_background, {:error, :foreground_refused}}` — Android refused
  `startForeground` asynchronously after `start/2` returned `:ok` (Android 14+
  while-in-use restrictions). The session is over afterwards (`status/0` is
  `:idle`, `update/1` returns `{:error, :not_running}`).
- `{:mob_background, {:error, :timeout}}` — Android 15 reached the `dataSync`
  6-hour background limit (`onTimeout`) and stopped the service. Session is
  over afterwards. (`:media_playback` and `:microphone` have no such limit.)

### Simple keep-alive (`keep_alive/0`)

```elixir
# Keep the app alive when the screen locks (e.g. in mount/2):
:ok = MobBackground.keep_alive()

# Allow suspension again when no longer needed:
:ok = MobBackground.stop()
```

`keep_alive/0` starts an owner-less `:data_sync` session with the default
low-importance notification (`mob_beam_fg`) when idle, and is an idempotent
no-op when any session (owner-bound or owner-less) is already running.

`status/0` returns `:idle`, `{:running, :data_sync}`, `{:running, :microphone}`,
`{:running, :media_playback}`,
or `{:error, reason}` without changing state. Run `mix mob.selftest` from a
host app to check on a device that the native side is linked and wired up.

## Modes

| Mode | Android FGS type | iOS behavior | Required runtime permission | Android 15 limit |
|------|------------------|--------------|-----------------------------|------------------|
| `:data_sync` | `dataSync` | Silent `AVAudioEngine` loop (`MixWithOthers`); no notification UI / actions | `POST_NOTIFICATIONS` for Android 13+ visibility only | 6h per 24h in background |
| `:microphone` | `microphone` | `{:error, :unsupported}` (use app's active recording `AVAudioSession` + `UIBackgroundModes: [audio]`) | Android `RECORD_AUDIO` granted + app in foreground (`Android 14+`) | None |
| `:media_playback` | `mediaPlayback` (host declares the `<service>`, see below) | Same as `:data_sync` | `POST_NOTIFICATIONS` for Android 13+ visibility only | None |

`:media_playback` is for apps that play audio the user hears (players,
instruments, radio); its notification uses `ic_media_play`.

## Install

```elixir
# mix.exs
{:mob_background, "~> 0.3"}

# mob.exs
config :mob, :plugins, [:mob_background]
config :mob, :trusted_plugins, %{mob_background: "ed25519:<fingerprint>"}
```

`mix mob.plugin.trust mob_background` records the fingerprint, then
`mix mob.deploy --native`.

## Host requirements (the native build warns about these)

On Android the build adds the plugin pieces automatically:
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and
`FOREGROUND_SERVICE_MICROPHONE` permissions, the `BeamForegroundService` class
(copied into `io/mob/background/` next to the bridge), and its `<service
android:foregroundServiceType="dataSync|microphone">` declaration. If you copied
`BeamForegroundService.kt` into your app for plugin 0.1.x somewhere other than
`io/mob/background/`, delete that copy.

`mob_background` deliberately does **not** add `android.permission.RECORD_AUDIO`
to the plugin permissions: hosts that use `:microphone` mode must declare
`RECORD_AUDIO` in their manifest (all `mix mob.new` projects already declare it)
and request it at runtime before calling `start(..., mode: :microphone, ...)`,
otherwise `start/2` returns `{:error, :permission}`. If you publish to Google
Play with `android:foregroundServiceType="microphone"` declared, complete the
matching foreground service declaration in Play Console.

The plugin deliberately doesn't add this one to your `Info.plist` (Apple
rejects the mode in apps with no audio feature, so it's the app author's
call); it prints as a warning on every `mix mob.deploy --native` of the host:

- **iOS `UIBackgroundModes`.** `Info.plist` must declare the `audio` mode (the
  keep-alive uses a silent audio session). `mix mob.new` adds this; for Xcode
  projects use *Signing & Capabilities → Background Modes → Audio, AirPlay, and
  Picture in Picture*. Apple rejects this mode for apps with no audio feature —
  only use this plugin in apps that legitimately use audio.

## Choosing the type: `:media_playback`

The type passed to `startForeground` must be one the `<service>` declares (API
29+), and Android 14+ also requires its `FOREGROUND_SERVICE_<TYPE>` permission. The
plugin doesn't declare `mediaPlayback` itself (Google Play asks every app to
justify each foreground-service type it declares), so a host that uses
`:media_playback` declares the service itself; the build then leaves that
declaration alone. In `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<!-- inside <application> -->
<service android:name="io.mob.background.BeamForegroundService"
    android:exported="false"
    android:foregroundServiceType="mediaPlayback" />
```

(`"dataSync|mediaPlayback"` allows both. `keep_alive/0` needs `dataSync`: in a
host whose `<service>` lacks it, `keep_alive/0` logs a warning and starts
nothing.) Without the type, `start(..., mode: :media_playback, ...)` returns
`{:error, :unavailable}`; without the permission (`targetSdk` 34+ on Android
14+) Android refuses `startForeground` and the owner gets
`{:mob_background, {:error, :foreground_refused}}`.

A host whose `<service>` doesn't declare `microphone` can drop the plugin's
`FOREGROUND_SERVICE_MICROPHONE` permission too: the build skips a plugin
permission the host manifest already names, and the manifest merger removes
an entry marked `tools:node="remove"` (declare
`xmlns:tools="http://schemas.android.com/tools"` on `<manifest>`):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"
    tools:node="remove" />
```

The same works for `FOREGROUND_SERVICE_DATA_SYNC` in a host that never uses
`:data_sync` or `keep_alive/0`.

## Notes

- **Coexistence with Mob.Audio:** playback mixes transparently (both use
  `MixWithOthers`); recording temporarily takes the audio session, and the
  keep-alive engine restarts automatically when recording (or a phone call)
  ends.
- **Android 14+ while-in-use rules:** start `:microphone` mode only while the
  app is in the foreground and `RECORD_AUDIO` is granted; starting from the
  background returns `{:error, :refused}` synchronously or delivers
  `{:mob_background, {:error, :foreground_refused}}` asynchronously.
- **Android notifications:** Android requires every foreground service to post
  a visible notification. `start/2` uses channel `"mob_background"`
  (`IMPORTANCE_DEFAULT`, silent/no vibration, `setOnlyAlertOnce`) so action
  buttons stay visible; `keep_alive/0` uses `"mob_beam_fg"` (`IMPORTANCE_LOW`).
  On Android 13+, `POST_NOTIFICATIONS` controls whether the notification appears
  in the status bar/shade (the service runs either way).
- **Android 15 time limit:** with `targetSdk` 35+, Android caps `dataSync`
  services at 6 hours per 24 hours in the background (`:microphone` and
  `:media_playback` have no cap). When `onTimeout` fires, the service logs a
  warning (`MobBackground` tag), sends `{:mob_background, {:error, :timeout}}`
  to the owner (if any), and stops itself.

## License

MIT.
