%% mob_background_nif — Erlang NIF module for the background-keep-alive plugin.
%%
%% iOS: priv/native/ios/mob_background_nif.m (Objective-C, a silent
%% AVAudioEngine session so the OS keeps the app running when the screen
%% locks). Android: priv/native/jni/mob_background_nif.zig (a zig NIF bridging
%% to the io.mob.background.MobBackgroundBridge Kotlin object, which starts /
%% stops the host's BeamForegroundService). Both register this module via
%% ERL_NIF_INIT and are statically linked into the host binary on device. On a
%% host dev build neither is linked, so on_load tolerates the failure and the
%% NIFs fall back to nif_error until the native merge links one.
-module(mob_background_nif).
-export([background_keep_alive/0, background_stop/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_background_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

background_keep_alive() ->
    erlang:nif_error(nif_not_loaded).

background_stop() ->
    erlang:nif_error(nif_not_loaded).
