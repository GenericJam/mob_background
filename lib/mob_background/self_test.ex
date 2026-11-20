defmodule MobBackground.SelfTest do
  @moduledoc """
  On-device proof (`Mob.Plugin.SelfTest`) for `mob_background`, run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  Runs one read-only native call, `background_status/0` (`MobBackground.status/0`),
  without starting a session: no foreground service, no notification, no audio
  session, nothing to undo.

  What proves the native side initialized:

    * **iOS:** the Objective-C NIF is linked and answers from the app's
      `Info.plist` and session state. `:idle`, `{:running, :data_sync}`, and
      `{:running, :media_playback}` pass. `{:error, :no_audio_background_mode}`
      fails: without `UIBackgroundModes` `audio` the silent session can't keep
      the app alive.
    * **Android:** the zig NIF answers `{:error, :bridge_not_registered}` until
      `MobBackgroundBridge.register()` has cached the bridge class and its
      method IDs; after that the answer comes from Kotlin, which checks the
      bridge has its Activity and that the app manifest declares
      `BeamForegroundService` with at least one `foregroundServiceType` the
      plugin can start (`dataSync`, `microphone`, or `mediaPlayback`; resolved
      through `PackageManager`, so it also proves the class the build copied
      in is the one declared). `:idle` and `{:running, :data_sync |
      :microphone | :media_playback}` pass; `:bridge_not_registered`,
      `:no_activity`, `:service_not_declared`, and `:service_not_data_sync`
      (none of those types declared) fail, since `keep_alive/0` and `start/2`
      would not work in that host.

  Any `{:running, mode}` passes because the app itself may hold a session on;
  the test doesn't touch it. Bare `:running` (legacy shape) and any other
  answer fail, as does the host stub's `nif_not_loaded`. Nothing here needs
  hardware or a user, so the test never skips.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_ctx) do
    classify(:mob_background_nif.background_status())
  rescue
    e in ErlangError ->
      {:fail, "mob_background_nif is not linked into this build: #{Exception.message(e)}"}
  end

  @doc false
  # Maps a background_status/0 answer to a self-test result.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(answer)

  def classify(:idle), do: :pass

  def classify({:running, mode}) when mode in [:data_sync, :microphone, :media_playback],
    do: :pass

  def classify({:error, :bridge_not_registered}),
    do:
      {:fail,
       "Kotlin MobBackgroundBridge not registered (nativeRegister never ran or a method-ID lookup failed)"}

  def classify({:error, :no_activity}),
    do: {:fail, "MobBackgroundBridge has no Activity (MobActivityAware.setActivity never called)"}

  def classify({:error, :service_not_declared}),
    do:
      {:fail, "AndroidManifest.xml declares no io.mob.background.BeamForegroundService <service>"}

  def classify({:error, :service_not_data_sync}),
    do:
      {:fail,
       "BeamForegroundService <service> declares none of dataSync, microphone, mediaPlayback in android:foregroundServiceType"}

  def classify({:error, :no_audio_background_mode}),
    do:
      {:fail,
       "Info.plist lacks UIBackgroundModes [audio]; the silent session can't keep the app alive"}

  def classify(other),
    do:
      {:fail,
       "background_status/0 returned #{inspect(other)}, expected :idle or {:running, :data_sync | :microphone | :media_playback}"}
end
