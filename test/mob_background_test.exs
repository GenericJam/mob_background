defmodule MobBackgroundTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

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

    test "declares the foreground-service permissions the FGS needs (API 34+ typed)",
         %{manifest: m} do
      assert "android.permission.FOREGROUND_SERVICE" in m.android.permissions
      assert "android.permission.FOREGROUND_SERVICE_DATA_SYNC" in m.android.permissions
    end

    test "declares the io.mob.background bridge class", %{manifest: m} do
      assert m.android.bridge_class == "io.mob.background.MobBackgroundBridge"
    end

    test "names AVFoundation as the iOS framework the keep-alive needs", %{manifest: m} do
      assert "AVFoundation" in m.ios.frameworks
    end

    test "host_requirements warns about the manual BeamForegroundService <service> landmine",
         %{manifest: m} do
      joined = Enum.join(m.host_requirements, "\n")
      assert joined =~ "BeamForegroundService"
      assert joined =~ "UIBackgroundModes"
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
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

      for fa <- [background_keep_alive: 0, background_stop: 0] do
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

      for fa <- [keep_alive: 0, stop: 0] do
        assert fa in exports, "#{inspect(fa)} missing from MobBackground"
      end
    end
  end
end
