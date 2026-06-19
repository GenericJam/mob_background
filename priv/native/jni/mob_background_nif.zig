//! mob_background_nif — Android background-keep-alive ZIG plugin NIF.
//!
//! The Kotlin side is the plugin-owned bridge object
//! `io.mob.background.MobBackgroundBridge`, which starts / stops the host's
//! `BeamForegroundService` (a foreground service that keeps the BEAM node
//! alive when the screen locks). `background_keep_alive` / `background_stop`
//! return :ok and invoke the matching static method on the bridge.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Registration: the JVM calls
//! `Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv, cls)` at
//! startup (MobPluginBootstrap.registerAll -> register()); that thunk caches
//! the bridge jclass + the 2 method IDs. Both bridge methods are arity-0
//! `()V`, so there are no varargs to marshal.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const BgMethods = struct {
    keep_alive: jni.JMethodID = null,
    stop: jni.JMethodID = null,
};

var g_bg: BgMethods = .{};
var g_bg_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
export fn Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_bg_cls = jni.newGlobalRef(jenv, cls);
    if (g_bg_cls == null) return;
    g_bg.keep_alive = jni.getStaticMethodID(jenv, cls, "background_keep_alive", "()V");
    g_bg.stop = jni.getStaticMethodID(jenv, cls, "background_stop", "()V");
}

// ── Thread-attach helper (mirror mob-core / touch) ────────────────────────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── NIFs ──────────────────────────────────────────────────────────────────
fn nif_background_keep_alive(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, g_bg_cls, g_bg.keep_alive);
    detachIfAttached(attached);
    return erts.ok(env);
}

fn nif_background_stop(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, g_bg_cls, g_bg.stop);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "background_keep_alive", .arity = 0, .fptr = nif_background_keep_alive, .flags = 0 },
    .{ .name = "background_stop", .arity = 0, .fptr = nif_background_stop, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_background_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_background_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
