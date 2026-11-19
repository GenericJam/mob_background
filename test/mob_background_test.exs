defmodule MobBackgroundTest do
  use ExUnit.Case, async: true

  alias MobBackground.SelfTest
  alias MobDev.NativeBuild
  alias MobDev.Plugin.{Manifest, Merge, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_background_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_background_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "declares the foreground-service permissions without claiming RECORD_AUDIO",
         %{manifest: m} do
      assert "android.permission.FOREGROUND_SERVICE" in m.android.permissions
      assert "android.permission.FOREGROUND_SERVICE_DATA_SYNC" in m.android.permissions
      assert "android.permission.FOREGROUND_SERVICE_MICROPHONE" in m.android.permissions
      refute "android.permission.RECORD_AUDIO" in m.android.permissions
    end

    test "declares the io.mob.background bridge class", %{manifest: m} do
      assert m.android.bridge_class == "io.mob.background.MobBackgroundBridge"
    end

    test "names AVFoundation as the iOS framework the keep-alive needs", %{manifest: m} do
      assert "AVFoundation" in m.ios.frameworks
    end

    test "host_requirements keeps the iOS UIBackgroundModes landmine and no longer asks for a manual Android service",
         %{manifest: m} do
      joined = Enum.join(m.host_requirements, "\n")
      assert joined =~ "UIBackgroundModes"
      refute joined =~ "BeamForegroundService"
      refute joined =~ "RECORD_AUDIO"
    end

    test "every native source dir + Kotlin file the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      for path <- Merge.bridge_kt_sources([{@plugin_dir, m}]) do
        assert File.exists?(path), "missing #{path}"
      end
    end

    test "declares the self-test, which passes the validator without a warning", %{manifest: m} do
      assert m.selftest == MobBackground.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  # MOB-423: the bridge referenced io.mob.background.BeamForegroundService but
  # the build copied only the bridge, so an unmodified host failed to compile.
  # These read the Kotlin through the same Merge calls the native build uses.
  describe "Android Kotlin the build copies into the host" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      plugins = [{@plugin_dir, manifest}]
      kotlin = Map.new(Merge.bridge_kt_sources(plugins), &{Path.basename(&1), File.read!(&1)})
      %{plugins: plugins, kotlin: kotlin}
    end

    test "all of it is in package io.mob.background, next to the bridge", %{kotlin: kotlin} do
      for {file, src} <- kotlin do
        assert NativeBuild.__parse_kotlin_package__(src) == "io.mob.background",
               "#{file} would land outside io/mob/background/"
      end
    end

    test "every class referenced via ::class is defined in a copied file or imported",
         %{kotlin: kotlin} do
      defined =
        for {_file, src} <- kotlin,
            [_, name] <- Regex.scan(~r/^(?:class|object)\s+(\w+)/m, src),
            do: name

      assert "BeamForegroundService" in defined

      for {file, src} <- kotlin, [_, ref] <- Regex.scan(~r/\b([A-Z]\w*)::class\b/, src) do
        imported? = Regex.match?(~r/^import\s+[\w.]+\.#{ref}\s*$/m, src)

        assert ref in defined or imported?,
               "#{file} references #{ref}, which no copied Kotlin file defines"
      end
    end

    test "every copied Service is declared in <application> with dataSync|microphone types",
         %{plugins: plugins, kotlin: kotlin} do
      snippets = for %{snippet: s} <- Merge.android_manifest_snippets(plugins), do: s

      services =
        for {_file, src} <- kotlin,
            [_, name] <- Regex.scan(~r/^class\s+(\w+)\s*:\s*Service\(\)/m, src),
            do: name

      assert "BeamForegroundService" in services

      for name <- services do
        fq = "io.mob.background.#{name}"
        snippet = Enum.find(snippets, &(&1 =~ ~s(android:name="#{fq}")))
        assert snippet, "no manifest_application_snippets entry declares #{fq}"
        assert snippet =~ ~s(android:foregroundServiceType="dataSync|microphone")
        assert snippet =~ ~s(android:exported="false")
      end

      # Both service type constants passed to startForeground must match the
      # manifest declaration or Android 14+ throws when the service starts.
      service_src = kotlin["BeamForegroundService.kt"]
      assert service_src =~ "FOREGROUND_SERVICE_TYPE_DATA_SYNC"
      assert service_src =~ "FOREGROUND_SERVICE_TYPE_MICROPHONE"
    end

    # MOB-505: Mob hosts compile against androidx.core 1.9, while ServiceCompat's
    # startForeground/stopForeground require androidx.core 1.12+.
    test "does not reference androidx ServiceCompat (MOB-505)", %{kotlin: kotlin} do
      for {file, src} <- kotlin do
        refute src =~ "ServiceCompat",
               "#{file} references ServiceCompat, which fails against androidx.core 1.9"
      end
    end
  end

  describe "MobBackground.SelfTest" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      assert {:fail, reason} = SelfTest.run(%{platform: :android, device: :emulator})
      assert reason =~ "mob_background_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?({:fail, reason})
    end

    test "a status answer from the native side passes for :idle and {:running, mode}" do
      for answer <- [:idle, {:running, :data_sync}, {:running, :microphone}] do
        assert SelfTest.classify(answer) == :pass
        assert Mob.Plugin.SelfTest.result?(SelfTest.classify(answer))
      end
    end

    test "a host where keep_alive/0 or start/2 would fail reports the cause" do
      cases = [
        bridge_not_registered: "MobBackgroundBridge not registered",
        no_activity: "has no Activity",
        service_not_declared: "declares no io.mob.background.BeamForegroundService",
        service_not_data_sync: ~s(foregroundServiceType="dataSync"),
        no_audio_background_mode: "UIBackgroundModes"
      ]

      for {reason, message} <- cases do
        assert {:fail, text} = result = SelfTest.classify({:error, reason})
        assert text =~ message
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "bare :running and unexpected answers fail instead of passing" do
      for answer <- [:running, :ok, {:error, :status_failed}, {:error, {:unknown_status, 9}}, nil] do
        assert {:fail, "background_status/0 returned " <> _} = result = SelfTest.classify(answer)
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_background_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_background_nif.module_info(:exports)

      for fa <- [
            background_keep_alive: 0,
            background_stop: 0,
            background_status: 0,
            background_start: 5,
            background_update: 3
          ] do
        assert fa in exports, "#{inspect(fa)} missing from mob_background_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_background_nif.background_stop()
      end
    end
  end

  describe "public API surface" do
    test "exports the documented operations" do
      exports = MobBackground.__info__(:functions)

      for fa <- [keep_alive: 0, stop: 0, status: 0, start: 1, start: 2, update: 1] do
        assert fa in exports, "#{inspect(fa)} missing from MobBackground"
      end
    end
  end

  describe "start and update validation (nif_args/2 and notification_nif_args/1)" do
    test "maps modes, defaults omitted :actions to [], and preserves owner" do
      owner = self()

      assert {^owner, 0, "Sync", "Uploading", []} =
               MobBackground.nif_args(owner,
                 mode: :data_sync,
                 notification: %{title: "Sync", text: "Uploading"}
               )

      assert {^owner, 1, "Mic", "Listening", []} =
               MobBackground.nif_args(owner,
                 mode: :microphone,
                 notification: %{title: "Mic", text: "Listening"}
               )
    end

    test "normalizes up to 3 actions and round-trips emoji titles, texts, and labels unchanged" do
      owner = self()

      notification = %{
        title: "🎙️ Listening · A4 −12¢",
        text: "Singing → FMutate 🎵",
        actions: [
          %{id: :pause, label: "⏸ Pause"},
          %{id: :record, label: "⏺ Record"},
          %{id: :stop, label: "Stop"}
        ]
      }

      expected_actions = [{:pause, "⏸ Pause"}, {:record, "⏺ Record"}, {:stop, "Stop"}]

      assert {^owner, 1, "🎙️ Listening · A4 −12¢", "Singing → FMutate 🎵", ^expected_actions} =
               MobBackground.nif_args(owner, mode: :microphone, notification: notification)

      assert {"🎙️ Listening · A4 −12¢", "Singing → FMutate 🎵", ^expected_actions} =
               MobBackground.notification_nif_args(notification)
    end

    test "rejects invalid owner, non-keyword opts, unknown options, and bad/missing mode" do
      valid_notif = %{title: "Title", text: "Body"}

      assert_raise ArgumentError, ~r/owner/, fn ->
        MobBackground.nif_args(:not_a_pid, mode: :data_sync, notification: valid_notif)
      end

      assert_raise ArgumentError, ~r/owner/, fn ->
        MobBackground.nif_args(nil, mode: :data_sync, notification: valid_notif)
      end

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        MobBackground.nif_args(self(), %{mode: :data_sync, notification: valid_notif})
      end

      assert_raise ArgumentError, ~r/unknown option/, fn ->
        MobBackground.nif_args(self(), mode: :data_sync, notification: valid_notif, extra: true)
      end

      assert_raise ArgumentError, ~r/missing required option :mode/, fn ->
        MobBackground.nif_args(self(), notification: valid_notif)
      end

      assert_raise ArgumentError, ~r/unknown mode/, fn ->
        MobBackground.nif_args(self(), mode: :location, notification: valid_notif)
      end
    end

    test "rejects missing, non-map, or malformed notification fields" do
      assert_raise ArgumentError, ~r/missing required option :notification/, fn ->
        MobBackground.nif_args(self(), mode: :data_sync)
      end

      assert_raise ArgumentError, ~r/map/, fn ->
        MobBackground.nif_args(self(), mode: :data_sync, notification: [title: "A", text: "B"])
      end

      assert_raise ArgumentError, ~r/unknown notification key/, fn ->
        MobBackground.notification_nif_args(%{title: "A", text: "B", action: []})
      end

      assert_raise ArgumentError, ~r/:title/, fn ->
        MobBackground.notification_nif_args(%{text: "Body"})
      end

      assert_raise ArgumentError, ~r/:text/, fn ->
        MobBackground.notification_nif_args(%{title: "Title"})
      end
    end

    test "rejects non-UTF-8 and oversized title/text/label strings" do
      bad_utf8 = <<0xFF, 0xFE>>
      too_long = String.duplicate("a", 1025)

      assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
        MobBackground.notification_nif_args(%{title: bad_utf8, text: "ok"})
      end

      assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
        MobBackground.notification_nif_args(%{title: "ok", text: bad_utf8})
      end

      assert_raise ArgumentError, ~r/1024 bytes/, fn ->
        MobBackground.notification_nif_args(%{title: too_long, text: "ok"})
      end

      assert_raise ArgumentError, ~r/1024 bytes/, fn ->
        MobBackground.notification_nif_args(%{title: "ok", text: too_long})
      end

      assert_raise ArgumentError, ~r/action :label must be valid UTF-8/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: :stop, label: bad_utf8}]
        })
      end

      assert_raise ArgumentError, ~r/action :label exceeds 1024 bytes/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: :stop, label: too_long}]
        })
      end
    end

    test "rejects invalid action shapes, non-atom ids, duplicate ids, and > 3 actions" do
      assert_raise ArgumentError, ~r/:actions must be a list/, fn ->
        MobBackground.notification_nif_args(%{title: "ok", text: "ok", actions: :none})
      end

      assert_raise ArgumentError, ~r/at most 3/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [
            %{id: :a, label: "A"},
            %{id: :b, label: "B"},
            %{id: :c, label: "C"},
            %{id: :d, label: "D"}
          ]
        })
      end

      assert_raise ArgumentError, ~r/atom/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: "stop", label: "Stop"}]
        })
      end

      assert_raise ArgumentError, ~r/atom/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: nil, label: "Stop"}]
        })
      end

      assert_raise ArgumentError, ~r/duplicate/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: :stop, label: "One"}, %{id: :stop, label: "Two"}]
        })
      end
    end

    test "rejects malformed action maps, unknown action keys, and boolean/empty atom ids" do
      assert_raise ArgumentError, ~r/expected action to be a map/, fn ->
        MobBackground.notification_nif_args(%{title: "ok", text: "ok", actions: [:stop]})
      end

      assert_raise ArgumentError, ~r/unknown action key/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: :stop, label: "Stop", extra: 1}]
        })
      end

      assert_raise ArgumentError, ~r/missing required action key :id/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{label: "Stop"}]
        })
      end

      assert_raise ArgumentError, ~r/missing required action key :label/, fn ->
        MobBackground.notification_nif_args(%{
          title: "ok",
          text: "ok",
          actions: [%{id: :stop}]
        })
      end

      for bad_id <- [true, false, :""] do
        assert_raise ArgumentError, ~r/atom/, fn ->
          MobBackground.notification_nif_args(%{
            title: "ok",
            text: "ok",
            actions: [%{id: bad_id, label: "Stop"}]
          })
        end
      end
    end
  end
end
