defmodule MobBackground do
  @moduledoc """
  Background execution keep-alive and typed foreground service — a Mob plugin.

  Keeps the BEAM node running when the screen locks or the app is backgrounded.
  On iOS this is a silent `AVAudioEngine` session; on Android it is a typed
  foreground service (`dataSync`, `microphone`, or `mediaPlayback`) with an
  optional dynamic notification and action buttons. Opt-in: add the dependency
  and activate it in `mob.exs`.

  ## Which plugin do I actually want?

  The background/wake/notify/push quartet gets mixed up regularly.
  Four distinct concerns:

  | I want to…                                             | Plugin                                                            |
  |--------------------------------------------------------|-------------------------------------------------------------------|
  | Keep my app alive continuously while backgrounded      | **`mob_background`** (this plugin)                                |
  | Run a handler only when the OS fires a scheduler / silent push | [`mob_wake`](https://hexdocs.pm/mob_wake) (device-side)   |
  | Schedule local notifications / register for push       | [`mob_notify`](https://hexdocs.pm/mob_notify) (device-side)       |
  | **Send** a push from my server                         | [`mob_push`](https://hexdocs.pm/mob_push) (server-side; no device code) |

  * **`mob_background` vs `mob_wake`:** background is a *keep-alive* —
    the app stays running while backgrounded so *your own* code (an
    active upload, a walking tracker, a music player, an audio monitor) can
    keep going. Wake is *event-driven* — the OS (or a silent push) fires a
    specific handler, it runs to completion, the platform reports done. They
    stack: an app can use both. Cost/benefit: `mob_background` needs an
    ongoing platform justification (audio on iOS, persistent notification on
    Android); `mob_wake` doesn't — but doesn't run continuously either.
  * **When in doubt:** if you're doing episodic work triggered by an
    external event, `mob_wake`. If you're doing continuous work the
    user has explicitly kicked off, `mob_background`. If you're
    supporting both patterns in the same app, activate both.

  ## Installation

      # mix.exs
      {:mob_background, "~> 0.3"}

      # mob.exs
      config :mob, :plugins, [:mob_background]
      config :mob, :trusted_plugins, %{mob_background: "ed25519:<fingerprint>"}

  `mix mob.plugin.trust mob_background` records the fingerprint, then
  `mix mob.deploy --native`.

  This plugin has one `host_requirement` the native build warns about on
  every `mix mob.deploy --native` of the host: the iOS `UIBackgroundModes`
  plist key (see *iOS → Requirements* below). The plugin deliberately
  doesn't add it to `Info.plist`: Apple rejects the mode in apps with no
  audio feature, so declaring it is the app author's call. The Android
  service class, its `<service>` declaration, and the `FOREGROUND_SERVICE*`
  permissions are added by the build.

  ## Usage

  ### Owner-bound typed session (`start/1,2` + `update/1`)

  Use `start/1,2` when your GenServer or LiveView needs a specific foreground
  service type (`:data_sync`, `:microphone`, or `:media_playback`), custom
  notification text, or interactive notification buttons:

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

      # Update the live notification (at most ~4 posts/s on Android; unchanged
      # updates skip JNI completely):
      :ok =
        MobBackground.update(%{
          title: "Paused",
          text: "Tap Resume to continue",
          actions: [%{id: :resume, label: "Resume"}, %{id: :stop, label: "Stop"}]
        })

      :ok = MobBackground.stop()

  ### Owner lifetime and messages

  `start/2` monitors the `owner` pid (`self()` by default in `start/1`):

  * When the owner process exits, the native layer automatically stops the
    service and removes the notification so it never outlives the process its
    buttons talk to.
  * Calling `start/2` while a session is already running retargets the owner
    monitor, switches mode and notification, and returns `:ok`.
  * Notification action taps are delivered to `owner` as:
    `{:mob_background, {:action, id}}` (where `id` is the atom from
    `actions`). Buttons do not mutate service state on their own; handle the
    message and call `update/1` or `stop/0`. If a tap cannot be delivered to
    an owner (for example, an owner-less `keep_alive/0` session updated with
    buttons, or an exited owner/BEAM), the Android service stops itself and the
    native layer ends the session on both sides.
  * If Android refuses `startForeground` asynchronously after `start/2`
    returned `:ok` (Android 14+ while-in-use rules: app left the foreground or
    `RECORD_AUDIO` was revoked), `owner` receives
    `{:mob_background, {:error, :foreground_refused}}` and the session ends
    (`status/0` becomes `:idle`, `update/1` returns `{:error, :not_running}`).
  * If Android 15 stops a `:data_sync` service at its 6-hour background time
    limit (`onTimeout`), `owner` receives `{:mob_background, {:error, :timeout}}`
    and the session ends.

  ### Legacy owner-less keep-alive (`keep_alive/0`)

  For simple keep-alive without an owner process or custom notification:

      # Keep the app alive when the screen locks (e.g. in mount/2):
      :ok = MobBackground.keep_alive()

      # Allow suspension again when background execution is no longer needed:
      :ok = MobBackground.stop()

  `keep_alive/0` is idempotent — safe to call multiple times. When idle, it
  starts an owner-less `:data_sync` session with the default low-importance
  notification (`mob_beam_fg`). When any session (owner-bound or owner-less)
  is already running, `keep_alive/0` is a no-op and does not override the
  running session.

  `status/0` is a read-only check that keep-alive can work in this host and
  whether a session is active (`:idle` or `{:running, mode}`);
  `MobBackground.SelfTest` uses it for `mix mob.selftest`.

  ## Modes

  | Mode | Android FGS type | iOS behaviour | Notification icon | Time limit (Android 15) |
  |------|------------------|---------------|-------------------|-------------------------|
  | `:data_sync` | `dataSync` | Silent `AVAudioEngine` keep-alive | `ic_dialog_info` | 6h / 24h in background |
  | `:microphone` | `microphone` | `{:error, :unsupported}` | `ic_btn_speak_now` | None |
  | `:media_playback` | `mediaPlayback` (host-declared, see *Choosing the type*) | Silent `AVAudioEngine` keep-alive (same as `:data_sync`) | `ic_media_play` | None |

  ## iOS — silent audio session

  iOS suspends apps when the screen locks unless they hold an active background
  execution mode. `keep_alive/0` and `start/2` with `mode: :data_sync` or
  `mode: :media_playback` start a silent `AVAudioEngine` looping a zero-filled
  buffer with `AVAudioSessionCategoryOptionMixWithOthers` — the OS sees an
  active audio session and keeps the process running, the user hears nothing,
  and any music already playing is undisturbed. The two modes behave the same
  on iOS; `status/0` reports the mode the session was started with.

  iOS has no persistent foreground-service notification surface: `notification`
  is validated and accepted, `update/1` returns `:ok` while running (and
  `{:error, :not_running}` when idle), nothing is shown on screen, and action
  messages never fire.

  `start/2` with `mode: :microphone` returns `{:error, :unsupported}` on iOS.
  iOS has no foreground-service equivalent; keeping an app alive while
  recording audio in the background is held directly by the app's own active
  recording `AVAudioSession` (`PlayAndRecord`) paired with
  `UIBackgroundModes: [audio]`.

  ### Requirements

  The app's `Info.plist` must declare the `audio` background mode:

      <key>UIBackgroundModes</key>
      <array>
          <string>audio</string>
      </array>

  This is included in all projects generated by `mix mob.new`. For Xcode
  projects, add it under *Signing & Capabilities → Background Modes →
  Audio, AirPlay, and Picture in Picture*.

  ### Coexistence with Mob.Audio

  **Playback** (`Mob.Audio.play/3`): both sides use `MixWithOthers`, so they
  mix transparently. The silent buffer is inaudible alongside real audio.

  **Recording** (`Mob.Audio.start_recording/2`): recording switches the global
  `AVAudioSession` category to `PlayAndRecord`, which sends an interruption to
  the keep-alive engine. The engine stops — but the recording itself holds an
  active audio session, so the app stays alive for the duration of the
  recording. When `stop_recording/1` is called and the session is released, iOS
  fires `AVAudioSessionInterruptionTypeEnded` and the keep-alive engine restarts
  automatically. No Elixir code is needed to handle this transition.

  The same automatic restart applies to phone calls and any other event that
  temporarily takes the audio session away from the app.

  ### Known limitation — observer cleanup

  Internally, the NIF registers an `NSNotificationCenter` observer for
  `AVAudioSessionInterruptionNotification` to handle the recording restart
  described above. When `stop/0` is called (or the owner process dies), it
  removes that observer by the token it stored, so it only removes its own
  observer.

  ### Apple's stance

  Apple permits the `audio` background mode for apps that legitimately use
  audio. Mob apps that use `Mob.Audio` recording or playback qualify. Apple
  will reject apps that declare this mode without any audio feature — do not
  add `UIBackgroundModes: [audio]` to an app that has no audio functionality.

  ## Android — foreground service

  On Android the OS equivalent of iOS background execution is a *foreground
  service*. `BeamForegroundService` starts in the foreground with `dataSync`,
  `microphone`, or `mediaPlayback` and a persistent notification. The OS
  will not kill a foreground service under memory pressure and will not pause
  the process when the screen locks.

  ### Choosing the type

  Android 14+ requires a foreground service to declare what it does: the
  `<service>`'s `android:foregroundServiceType` in the manifest, a matching
  `FOREGROUND_SERVICE_<TYPE>` permission, and the type passed to
  `startForeground`, which must be one the manifest declares. The manifest is
  fixed at build time, so the type is chosen in two places:

    * `:data_sync` (and `keep_alive/0`) / `:microphone`: the build declares
      the service as `dataSync|microphone` and adds
      `FOREGROUND_SERVICE_DATA_SYNC` and `FOREGROUND_SERVICE_MICROPHONE`.
      Android 15 limits `dataSync` to 6 hours per 24 in the background (see
      below).
    * `:media_playback`: for apps that play audio the user hears (players,
      instruments, radio). No time limit. The host declares the service
      itself, in `android/app/src/main/AndroidManifest.xml`; the build then
      leaves that declaration alone:

          <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
          ...
          <application ...>
              <service android:name="io.mob.background.BeamForegroundService"
                  android:exported="false"
                  android:foregroundServiceType="mediaPlayback" />

      (`"dataSync|mediaPlayback"` declares both, for an app that uses
      either; `keep_alive/0` needs `dataSync`.) The plugin doesn't declare
      `mediaPlayback` for every host: Google Play asks each app to justify
      every foreground-service type it declares.

  `start/2` returns `{:error, :unavailable}` when the `<service>` doesn't
  declare the requested mode's type. A missing `FOREGROUND_SERVICE_<TYPE>`
  permission makes Android refuse `startForeground`, which reaches the owner
  as `{:mob_background, {:error, :foreground_refused}}`.

  A host whose own `<service>` doesn't declare `microphone` can also drop the
  plugin's `FOREGROUND_SERVICE_MICROPHONE` permission (so Google Play doesn't
  ask about it): the build skips any plugin permission the host manifest
  already names, and the manifest merger removes an entry marked
  `tools:node="remove"` (with `xmlns:tools="http://schemas.android.com/tools"`
  on `<manifest>`):

      <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"
          tools:node="remove" />

  The same works for `FOREGROUND_SERVICE_DATA_SYNC` in a host that never uses
  `:data_sync` or `keep_alive/0`.

  ### Android 14+ while-in-use rules & permissions

  * **Foreground-only start:** Android 12+/14+ only allows starting a
    foreground service while the app is in the foreground (especially
    `microphone` services under Android 14+ while-in-use restrictions). Start
    from a foreground user action; starting while backgrounded returns
    `{:error, :refused}` synchronously or delivers
    `{:mob_background, {:error, :foreground_refused}}` asynchronously.
  * **`RECORD_AUDIO` for `:microphone` mode:** The plugin manifest declares
    `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and
    `FOREGROUND_SERVICE_MICROPHONE`, and intentionally does **not** declare
    `RECORD_AUDIO`. Host apps that use `:microphone` mode must declare
    `android.permission.RECORD_AUDIO` in their own `AndroidManifest.xml`
    (`mix mob.new` hosts already declare it) and grant it at runtime before
    calling `start(..., mode: :microphone, ...)`, or `start/2` returns
    `{:error, :permission}`.
  * **Google Play Console declaration:** The plugin's merged `<service>`
    declares `android:foregroundServiceType="dataSync|microphone"` (or the
    types of the host's own `<service>`, see *Choosing the type*); apps
    published to Google Play must complete the foreground service declaration
    for the types they ship in Play Console.

  ### Visible notification (required by Android)

  Android requires every foreground service to have a notification. There is
  no API to hide it:

  * `start/2` posts on the `"mob_background"` channel (`IMPORTANCE_DEFAULT`
    with sound/vibration disabled and `setOnlyAlertOnce(true)` so action
    buttons remain visible instead of being folded into Android's "Silent"
    bucket).
  * `keep_alive/0` posts on the `"mob_beam_fg"` channel (`IMPORTANCE_LOW`)
    with the app name and `"Running in background"`.
  * On Android 13+ (API 33) the notification is only *shown* in the status bar
    and drawer when the app holds `POST_NOTIFICATIONS` — declared and granted
    at runtime (activate `mob_notify` and request `:notifications`). Without
    it the foreground service still runs (verified on Android 15) but users
    only see it in the system's running-apps list.

  ### Requirements

  The build adds the Android pieces automatically when the plugin is activated:
  `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, and
  `FOREGROUND_SERVICE_MICROPHONE` permissions, the `BeamForegroundService`
  class (copied into the app's sources next to the bridge), and its
  declaration inside `<application>`:

      <service android:name="io.mob.background.BeamForegroundService"
          android:exported="false"
          android:foregroundServiceType="dataSync|microphone" />

  If your app has its own copy of `BeamForegroundService.kt` (from plugin
  0.1.x, which asked you to copy it in) outside `io/mob/background/`, delete
  it: the build's copy now provides the class and two would not compile. A
  copy at `io/mob/background/BeamForegroundService.kt` is overwritten by the
  build. A `<service>` you declared by hand is left as is.

  ### Stop behaviour

  `stop/0` stops any active session (owner-bound or owner-less), cancelling
  the owner monitor if present. If `start/2` has handed `startForegroundService`
  to Android and `onStartCommand` has not reached `startForeground` yet, the
  bridge defers `stopSelf()` until `startForeground` completes so Android never
  crashes with `"Context.startForegroundService() did not then call Service.startForeground()"`.
  If the BEAM node goes silent (no incoming distribution traffic) the OS may
  still eventually kill the process — background keep-alive prevents
  aggressive *background process killing* but not an eventual idle OOM kill
  after many hours of complete inactivity.

  ### Android 15 time limit

  With `targetSdk` 35+, Android allows a `dataSync` foreground service at most
  6 hours per 24 hours while the app is in the background (`:microphone` and
  `:media_playback` have no such cap). When the limit is reached the system
  calls `onTimeout`, which logs a warning (tag `MobBackground`), notifies the
  owner with `{:mob_background, {:error, :timeout}}`, clears running state, and
  stops the service so the app does not crash. Call `start/2` or
  `keep_alive/0` again once the app is back in the foreground, or use
  `:media_playback` if the app plays audio.

  ## Validation limits

  `start/1,2` and `update/1` raise `ArgumentError` before touching native code
  when arguments are invalid:

  * `opts` must be a keyword list containing only `:mode` (required) and
    `:notification` (required).
  * `mode` must be `:data_sync`, `:microphone`, or `:media_playback`.
  * `notification` must be a plain map with required `:title` and `:text`
    keys (valid UTF-8 binaries, at most `1024` bytes each) and optional
    `:actions` (defaults to `[]`).
  * `actions` may contain at most `3` plain maps `%{id: atom(), label: String.t()}`
    (Android's compact notification limit).
  * Each action `:id` must be a unique non-`nil`, non-boolean, non-empty atom
    whose UTF-8 name is `1..255` bytes without NUL bytes; `:label` must be a
    valid UTF-8 binary of at most `1024` bytes.
  """

  @max_text_bytes 1024
  @max_action_id_bytes 255
  @max_actions 3
  @valid_opt_keys [:mode, :notification]
  @valid_notification_keys [:title, :text, :actions]
  @valid_action_keys [:id, :label]

  @type mode :: :data_sync | :microphone | :media_playback
  @type action :: %{id: atom(), label: String.t()}
  @type notification :: %{
          required(:title) => String.t(),
          required(:text) => String.t(),
          optional(:actions) => [action()]
        }

  @doc """
  Starts the typed background session bound to `self()`, using `opts`.

  Equivalent to `start(self(), opts)`. See `start/2` for options, return
  values, and owner messages.
  """
  @spec start(keyword()) ::
          :ok | {:error, :permission | :refused | :unavailable | :owner_dead | :unsupported}
  def start(opts), do: start(self(), opts)

  @doc """
  Starts (or retargets) the typed foreground service / keep-alive session bound
  to `owner`.

  Options (`opts`):

    * `:mode` (required) — `:data_sync`, `:microphone`, or `:media_playback`
      (Android: the host's `<service>` must declare `mediaPlayback`, see
      *Choosing the type*).
    * `:notification` (required) — `%{title: String.t(), text: String.t(), actions: [%{id: atom(), label: String.t()}]}`
      (`:actions` is optional, max 3 actions).

  Returns `:ok`, or one of:

    * `{:error, :permission}` — Android `:microphone` mode without `RECORD_AUDIO` granted.
    * `{:error, :refused}` — Android refused `startForegroundService` synchronously
      (for example app in background) or a JNI error occurred.
    * `{:error, :unavailable}` — Android bridge not registered, no Activity, or
      `BeamForegroundService` missing from manifest / missing the requested
      `foregroundServiceType` (`mediaPlayback` for `:media_playback`).
    * `{:error, :owner_dead}` — `owner` was already dead when installing the
      monitor (the just-started service is stopped).
    * `{:error, :unsupported}` — platform does not support the requested mode
      (`:microphone` on iOS).
  """
  @spec start(pid(), keyword()) ::
          :ok | {:error, :permission | :refused | :unavailable | :owner_dead | :unsupported}
  def start(owner, opts) do
    {owner_arg, mode_code, title, text, actions} = nif_args(owner, opts)
    :mob_background_nif.background_start(owner_arg, mode_code, title, text, actions)
  end

  @doc """
  Updates the live notification for the currently running session (including an
  owner-less `keep_alive/0` session).

  On Android, unchanged notifications skip the JNI call completely and rapid
  updates are coalesced to at most one post per 250 ms. On iOS, returns `:ok`
  when running without showing any UI. Returns `{:error, :not_running}` when
  idle.
  """
  @spec update(notification()) :: :ok | {:error, :not_running}
  def update(notification) do
    {title, text, actions} = notification_nif_args(notification)
    :mob_background_nif.background_update(title, text, actions)
  end

  @doc """
  Starts an owner-less `:data_sync` keep-alive (silent audio session on iOS,
  default low-priority foreground service notification on Android) if idle.

  Idempotent — safe to call more than once. Does nothing and returns `:ok` if
  any session (owner-bound or owner-less) is already running. If that is an
  owner session from `start/2`, the process keeps running only as long as that
  session does: it ends when its owner exits, Android refuses or times it out,
  or `stop/0` is called. Don't mix the two in one app unless that is intended.
  """
  @spec keep_alive() :: :ok
  def keep_alive do
    :mob_background_nif.background_keep_alive()
  end

  @doc """
  Stops any active background session (owner-bound or owner-less), cancels the
  owner monitor, and removes the Android notification. Idempotent.
  """
  @spec stop() :: :ok
  def stop do
    :mob_background_nif.background_stop()
  end

  @doc """
  Reports, without changing anything, whether background keep-alive can work in
  this host and whether a session is currently running.

    * `:idle` — ready; no session is running.
    * `{:running, :data_sync}` — active in `:data_sync` mode (either from
      `keep_alive/0` or `start/2`).
    * `{:running, :microphone}` — active in `:microphone` mode (Android).
    * `{:running, :media_playback}` — active in `:media_playback` mode.
    * `{:error, :no_audio_background_mode}` — iOS: `Info.plist` lacks
      `UIBackgroundModes` `audio`.
    * `{:error, :bridge_not_registered}` — Android: `MobBackgroundBridge`
      never registered with the NIF (`MobPluginBootstrap.registerAll` didn't
      run, or a method lookup failed).
    * `{:error, :no_activity}` — Android: the bridge never received an
      Activity, so `keep_alive/0` and `start/2` cannot start the service.
    * `{:error, :service_not_declared}` / `{:error, :service_not_data_sync}`
      — Android: the app manifest has no `BeamForegroundService` `<service>`,
      or declares it with none of the types the plugin can start (`dataSync`,
      `microphone`, `mediaPlayback`). The atom keeps its 0.3.0 name; a
      `<service>` declaring only `mediaPlayback` (or only `microphone`) is
      not reported.
    * `{:error, :no_jni_env}`, `{:error, :status_failed}`,
      `{:error, {:unknown_status, code}}` — Android: the query itself failed.
  """
  @spec status() :: :idle | {:running, mode()} | {:error, term()}
  def status do
    :mob_background_nif.background_status()
  end

  @doc false
  @spec nif_args(pid(), keyword()) ::
          {pid(), 0 | 1 | 2, String.t(), String.t(), [{atom(), String.t()}]}
  def nif_args(owner, opts) do
    unless is_pid(owner) do
      raise ArgumentError, "expected owner to be a pid, got: #{inspect(owner)}"
    end

    unless Keyword.keyword?(opts) do
      raise ArgumentError, "expected opts to be a keyword list, got: #{inspect(opts)}"
    end

    unknown =
      opts
      |> Keyword.keys()
      |> Enum.reject(&(&1 in @valid_opt_keys))
      |> Enum.uniq()

    if unknown != [] do
      raise ArgumentError, "unknown option(s) in start opts: #{inspect(unknown)}"
    end

    mode_code = encode_mode!(Keyword.fetch(opts, :mode))

    notification =
      case Keyword.fetch(opts, :notification) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "missing required option :notification"
      end

    {title, text, actions} = notification_nif_args(notification)
    {owner, mode_code, title, text, actions}
  end

  @doc false
  @spec notification_nif_args(notification()) :: {String.t(), String.t(), [{atom(), String.t()}]}
  def notification_nif_args(notification) do
    unless is_map(notification) and not is_struct(notification) do
      raise ArgumentError, "expected notification to be a map, got: #{inspect(notification)}"
    end

    unknown = Map.keys(notification) -- @valid_notification_keys

    if unknown != [] do
      raise ArgumentError, "unknown notification key(s): #{inspect(unknown)}"
    end

    title = fetch_utf8_text!(notification, :title, "notification")
    text = fetch_utf8_text!(notification, :text, "notification")
    raw_actions = fetch_actions!(notification)

    if length(raw_actions) > @max_actions do
      raise ArgumentError,
            "at most #{@max_actions} notification actions are allowed, got: #{length(raw_actions)}"
    end

    {actions, _seen} =
      Enum.map_reduce(raw_actions, MapSet.new(), fn action, seen ->
        {id, label} = normalize_action!(action)

        if MapSet.member?(seen, id) do
          raise ArgumentError, "duplicate notification action id: #{inspect(id)}"
        end

        {{id, label}, MapSet.put(seen, id)}
      end)

    {title, text, actions}
  end

  defp encode_mode!({:ok, :data_sync}), do: 0
  defp encode_mode!({:ok, :microphone}), do: 1
  defp encode_mode!({:ok, :media_playback}), do: 2

  defp encode_mode!({:ok, other}) do
    raise ArgumentError,
          "unknown mode #{inspect(other)}, expected :data_sync, :microphone, or :media_playback"
  end

  defp encode_mode!(:error) do
    raise ArgumentError, "missing required option :mode"
  end

  defp fetch_utf8_text!(map, key, context) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        unless String.valid?(value) do
          raise ArgumentError, "#{context} #{inspect(key)} must be valid UTF-8"
        end

        if byte_size(value) > @max_text_bytes do
          raise ArgumentError,
                "#{context} #{inspect(key)} exceeds #{@max_text_bytes} bytes (got #{byte_size(value)})"
        end

        value

      {:ok, other} ->
        raise ArgumentError,
              "#{context} #{inspect(key)} must be a UTF-8 string, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "missing required #{context} key #{inspect(key)}"
    end
  end

  defp fetch_actions!(notification) do
    case Map.fetch(notification, :actions) do
      :error ->
        []

      {:ok, actions} when is_list(actions) ->
        actions

      {:ok, other} ->
        raise ArgumentError, "notification :actions must be a list, got: #{inspect(other)}"
    end
  end

  defp normalize_action!(action) do
    unless is_map(action) and not is_struct(action) do
      raise ArgumentError, "expected action to be a map, got: #{inspect(action)}"
    end

    unknown = Map.keys(action) -- @valid_action_keys

    if unknown != [] do
      raise ArgumentError, "unknown action key(s): #{inspect(unknown)}"
    end

    id = fetch_action_id!(action)
    label = fetch_utf8_text!(action, :label, "action")
    {id, label}
  end

  defp fetch_action_id!(action) do
    case Map.fetch(action, :id) do
      {:ok, id} when is_atom(id) and id not in [nil, true, false, :""] ->
        id_str = Atom.to_string(id)

        if byte_size(id_str) > @max_action_id_bytes do
          raise ArgumentError,
                "action :id #{inspect(id)} exceeds #{@max_action_id_bytes} UTF-8 bytes"
        end

        if String.contains?(id_str, <<0>>) do
          raise ArgumentError, "action :id must not contain NUL bytes: #{inspect(id)}"
        end

        id

      {:ok, other} ->
        raise ArgumentError,
              "action :id must be a non-empty, non-boolean atom, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "missing required action key :id"
    end
  end
end
