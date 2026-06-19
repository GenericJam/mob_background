%{
  name: :mob_background,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "Background execution keep-alive: iOS silent AVAudioEngine session / Android dataSync foreground service",
  nifs: [
    # iOS: Objective-C NIF — a silent AVAudioEngine session (MixWithOthers) so
    # the OS keeps the app running when the screen locks. lang: :objc
    # (-fobjc-arc); platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_background_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the foreground-service start/stop in the
    # Kotlin io.mob.background.MobBackgroundBridge.
    %{module: :mob_background_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobBackgroundBridge.kt",
    # Implements MobActivityAware — it needs the Activity Context to start the
    # foreground service.
    bridge_class: "io.mob.background.MobBackgroundBridge",
    # The foreground service these permissions cover (API 34+ split out the
    # typed one). The service itself is a host-package <service> the plugin
    # manifest can't contribute — see :host_requirements below.
    permissions: [
      "android.permission.FOREGROUND_SERVICE",
      "android.permission.FOREGROUND_SERVICE_DATA_SYNC"
    ]
  },
  ios: %{
    # The keep-alive uses AVAudioEngine / AVAudioSession.
    frameworks: ["AVFoundation"]
  },
  # Manual host-app steps the build can't automate; printed as a warning on
  # every `mix mob.deploy --native` of the host.
  host_requirements: [
    "Android: AndroidManifest.xml must declare the keep-alive service inside " <>
      "<application>: " <>
      ~s(<service android:name="io.mob.background.BeamForegroundService" ) <>
      ~s(android:exported="false" android:foregroundServiceType="dataSync" />) <>
      " — a foreground service must be a host-package class; without it " <>
      "keep_alive/0 starts nothing.",
    "iOS: Info.plist must declare UIBackgroundModes [audio] (the keep-alive " <>
      "uses a silent audio session). Apple rejects this mode for apps with no " <>
      "audio feature.",
    "Android: the BeamForegroundService source ships in this package under " <>
      "priv/native/android/BeamForegroundService.kt — copy it into your app's " <>
      "host package (the build copies only bridge_kt automatically)."
  ]
}
