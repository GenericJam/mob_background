defmodule MobBackground.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native call, `background_status/0` (`MobBackground.status/0`).
  It never starts the keep-alive: no foreground service, no notification, no
  audio session, nothing to undo.

  What proves the native side initialized:

    * **iOS:** the Objective-C NIF is linked and answers from the app's
      `Info.plist` and the keep-alive flag. `:idle` / `:running` pass.
      `{:error, :no_audio_background_mode}` fails: without
      `UIBackgroundModes` `audio` the silent session can't keep the app alive.
    * **Android:** the zig NIF answers `{:error, :bridge_not_registered}` until
      `MobBackgroundBridge.register()` has cached the bridge class and its
      `background_status` method; after that the answer comes from Kotlin,
      which checks the bridge has its Activity and that the app manifest
      declares `BeamForegroundService` with `foregroundServiceType="dataSync"`
      (resolved through `PackageManager`, so it also proves the class the
      build copied in is the one declared). `:idle` / `:running` pass;
      `:bridge_not_registered`, `:no_activity`, `:service_not_declared` and
      `:service_not_data_sync` fail, since `keep_alive/0` would silently do
      nothing in that host.

  `:running` passes because the app itself may hold the keep-alive on; the
  test doesn't touch it. Any other answer fails, and so does the host stub's
  `nif_not_loaded` (the NIF isn't linked into the build). Nothing here needs
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

  def classify(status) when status in [:idle, :running], do: :pass

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
      {:fail, "BeamForegroundService <service> lacks android:foregroundServiceType=\"dataSync\""}

  def classify({:error, :no_audio_background_mode}),
    do:
      {:fail,
       "Info.plist lacks UIBackgroundModes [audio]; the silent session can't keep the app alive"}

  def classify(other),
    do: {:fail, "background_status/0 returned #{inspect(other)}, expected :idle or :running"}
end
