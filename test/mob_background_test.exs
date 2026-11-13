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

    test "declares the foreground-service permissions the default dataSync FGS needs (API 34+ typed), and not mediaPlayback's",
         %{manifest: m} do
      assert "android.permission.FOREGROUND_SERVICE" in m.android.permissions
      assert "android.permission.FOREGROUND_SERVICE_DATA_SYNC" in m.android.permissions
      # A host that keeps alive with type: :media_playback declares it itself.
      refute "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" in m.android.permissions
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

    test "every copied Service is declared in <application> as a dataSync foreground service",
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
        assert snippet =~ ~s(android:foregroundServiceType="dataSync")
        assert snippet =~ ~s(android:exported="false")
      end

      # The type startForeground passes must be a declared one, or Android 14+
      # throws when the service starts: dataSync for the plugin's declaration.
      assert kotlin["BeamForegroundService.kt"] =~ "FOREGROUND_SERVICE_TYPE_DATA_SYNC"
    end

    test "every type keep_alive/1 accepts is one the service starts with and the bridge checks the permission of",
         %{kotlin: kotlin} do
      service = kotlin["BeamForegroundService.kt"]
      bridge = kotlin["MobBackgroundBridge.kt"]
      [supported] = Regex.run(~r/SUPPORTED_TYPES =\s*([^\n]+)/, service, capture: :all_but_first)

      for {type, constant, permission} <- [
            {:data_sync, "FOREGROUND_SERVICE_TYPE_DATA_SYNC", "FOREGROUND_SERVICE_DATA_SYNC"},
            {:media_playback, "FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK",
             "FOREGROUND_SERVICE_MEDIA_PLAYBACK"}
          ] do
        assert {_, "", ""} = MobBackground.nif_args(type: type)
        assert supported =~ constant, "#{type}: #{constant} not in SUPPORTED_TYPES"

        assert bridge =~ ~r/ServiceInfo\.#{constant} -> "android\.permission\.#{permission}"/,
               "#{type}: the bridge doesn't check #{permission}"
      end
    end
  end

  describe "keep_alive/1 options" do
    test "default to a dataSync service with the default notification text" do
      # ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC = 1; "" = the default.
      assert MobBackground.nif_args([]) == {1, "", ""}
    end

    test "media playback, title and text reach the NIF" do
      # ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK = 2
      assert MobBackground.nif_args(
               type: :media_playback,
               title: "FMutate",
               text: "FMutate is playing"
             ) ==
               {2, "FMutate", "FMutate is playing"}
    end

    test "an unknown type or option raises instead of starting a service Android would refuse" do
      assert_raise ArgumentError, ~r/unknown keep-alive type :location/, fn ->
        MobBackground.keep_alive(type: :location)
      end

      assert_raise ArgumentError, ~r/unknown keys \[:txt\]/, fn ->
        MobBackground.keep_alive(txt: "hi")
      end
    end

    test "notification strings up to 255 bytes of UTF-8 pass; longer, NUL or non-UTF-8 raise" do
      longest = String.duplicate("é", 127) <> "a"
      assert byte_size(longest) == 255
      assert {1, ^longest, ""} = MobBackground.nif_args(title: longest)

      for {bad, message} <- [
            {longest <> "a", "longer than 255 bytes"},
            {"a\0b", "NUL"},
            {<<0xFF>>, "UTF-8"},
            {:playing, "UTF-8"}
          ] do
        assert_raise ArgumentError, ~r/#{message}/, fn -> MobBackground.nif_args(text: bad) end
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

    test "a status answer from the native side passes, whether keep-alive is off or on" do
      for answer <- [:idle, :running] do
        assert SelfTest.classify(answer) == :pass
        assert Mob.Plugin.SelfTest.result?(SelfTest.classify(answer))
      end
    end

    test "a host where keep_alive/0 would silently do nothing fails, naming the cause" do
      cases = [
        bridge_not_registered: "MobBackgroundBridge not registered",
        no_activity: "has no Activity",
        service_not_declared: "declares no io.mob.background.BeamForegroundService",
        service_type_unsupported: "neither dataSync nor mediaPlayback",
        no_audio_background_mode: "UIBackgroundModes"
      ]

      for {reason, message} <- cases do
        assert {:fail, text} = result = SelfTest.classify({:error, reason})
        assert text =~ message
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "an unexpected answer fails instead of passing" do
      for answer <- [:ok, {:error, :status_failed}, {:error, {:unknown_status, 9}}, nil] do
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

      for fa <- [background_keep_alive: 3, background_stop: 0, background_status: 0] do
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

      for fa <- [keep_alive: 0, keep_alive: 1, stop: 0, status: 0] do
        assert fa in exports, "#{inspect(fa)} missing from MobBackground"
      end
    end
  end
end
