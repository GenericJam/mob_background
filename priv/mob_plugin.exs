%{
  name: :mob_background,
  mob_version: "~> 0.9",
  # On-device proof for `mix mob.selftest` / mob_ci: the read-only
  # background_status/0 NIF (see MobBackground.SelfTest).
  selftest: MobBackground.SelfTest,
  plugin_spec_version: 1,
  description:
    "Background execution keep-alive and typed foreground service: iOS silent AVAudioEngine session / Android dataSync|microphone foreground service",
  nifs: [
    # iOS: Objective-C NIF — a silent AVAudioEngine session (MixWithOthers) so
    # the OS keeps the app running when the screen locks. lang: :objc
    # (-fobjc-arc); platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_background_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the typed foreground-service bridge in
    # io.mob.background.MobBackgroundBridge.
    %{module: :mob_background_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  android: %{
    # Both files are copied into the host's Kotlin sourceSet at their package
    # path (io/mob/background/). BeamForegroundService is the foreground
    # service MobBackgroundBridge starts; it has to be compiled into the app,
    # and an older host copy at that path is overwritten rather than duplicated.
    bridge_kt: [
      "priv/native/android/MobBackgroundBridge.kt",
      "priv/native/android/BeamForegroundService.kt"
    ],
    # Implements MobActivityAware — it needs the Activity Context to start the
    # foreground service and check permissions.
    bridge_class: "io.mob.background.MobBackgroundBridge",
    # Foreground service permissions (API 34+ split out per-type permissions).
    # RECORD_AUDIO is deliberately NOT declared here: hosts using :microphone
    # mode declare and request RECORD_AUDIO themselves (mob_new hosts already
    # declare it).
    permissions: [
      "android.permission.FOREGROUND_SERVICE",
      "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
      "android.permission.FOREGROUND_SERVICE_MICROPHONE"
    ],
    # Spliced into the host's <application>; skipped when the host already
    # declares a component with this android:name. The types must match
    # FOREGROUND_SERVICE_TYPE_DATA_SYNC / FOREGROUND_SERVICE_TYPE_MICROPHONE
    # that BeamForegroundService passes to startForeground.
    manifest_application_snippets: [
      """
      <service android:name="io.mob.background.BeamForegroundService"
          android:exported="false"
          android:foregroundServiceType="dataSync|microphone" />
      """
    ]
  },
  ios: %{
    # The keep-alive uses AVAudioEngine / AVAudioSession.
    frameworks: ["AVFoundation"]
  },
  # Manual host-app steps the build can't automate; printed as a warning on
  # every `mix mob.deploy --native` of the host.
  host_requirements: [
    "iOS: Info.plist must declare UIBackgroundModes [audio] (the keep-alive " <>
      "uses a silent audio session). Apple rejects this mode for apps with no " <>
      "audio feature."
  ]
}
