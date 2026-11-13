//! mob_background_nif — Android background-keep-alive ZIG plugin NIF.
//!
//! The Kotlin side is the plugin-owned bridge object
//! `io.mob.background.MobBackgroundBridge`, which starts / stops the host's
//! `BeamForegroundService` (a foreground service that keeps the BEAM node
//! alive when the screen locks). `background_keep_alive(type, title, text)`
//! starts it with a foreground-service type and the notification's title and
//! text, and returns `:ok` or `{:error, reason}` (see `statusTerm`);
//! `background_stop` returns :ok. `background_status` is read-only: it
//! returns `:idle` / `:running`, or `{:error, reason}` when the bridge never
//! registered or keep-alive can't work in this host.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Registration: the JVM calls
//! `Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv, cls)` at
//! startup (MobPluginBootstrap.registerAll -> register()); that thunk caches
//! the bridge jclass + the 3 method IDs: `(ILjava/lang/String;Ljava/lang/String;)I`
//! keep_alive, `()V` stop, `()I` status.
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
    status: jni.JMethodID = null,
};

var g_bg: BgMethods = .{};
var g_bg_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
export fn Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_bg_cls = jni.newGlobalRef(jenv, cls);
    if (g_bg_cls == null) return;
    // A missing method leaves a NoSuchMethodError pending on the JNIEnv —
    // clearing here matches mob core's cache pattern (see mob_ui_cache_class
    // in mob/android/jni/mob_nif.zig) so the exception does not leak into
    // any later BEAM-thread JNI call.
    g_bg.keep_alive = jni.getStaticMethodID(jenv, cls, "background_keep_alive", "(ILjava/lang/String;Ljava/lang/String;)I");
    if (g_bg.keep_alive == null) jni.exceptionClear(jenv);
    g_bg.stop = jni.getStaticMethodID(jenv, cls, "background_stop", "()V");
    if (g_bg.stop == null) jni.exceptionClear(jenv);
    g_bg.status = jni.getStaticMethodID(jenv, cls, "background_status", "()I");
    if (g_bg.status == null) jni.exceptionClear(jenv);
}

// ── Thread-attach helper (mirror mob-core / touch) ────────────────────────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── NIFs ──────────────────────────────────────────────────────────────────
// keep_alive and status report a missing bridge or JNI env as an error; stop
// returns `:ok` regardless, so it is always safe to call. `exceptionClear`
// after each JNI call prevents a pending Kotlin exception from leaking to the
// next JNI call — see MOB-59 and CHANGELOG for the failure modes.

// Copies a binary into `buf` as a NUL-terminated string for NewStringUTF.
// null when it doesn't fit or holds a NUL (MobBackground checks both first).
fn cString(bin: erts.ErlNifBinary, buf: []u8) ?[*:0]const u8 {
    if (bin.size >= buf.len) return null;
    const bytes = bin.data[0..bin.size];
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
    @memcpy(buf[0..bin.size], bytes);
    buf[bin.size] = 0;
    return @ptrCast(buf.ptr);
}

// keep_alive(type, title, text): type is a ServiceInfo FOREGROUND_SERVICE_TYPE_*
// int, title / text UTF-8 binaries ("" = the defaults), each < 256 bytes.
fn nif_background_keep_alive(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var fgs_type: c_int = 0;
    var title_bin: erts.ErlNifBinary = undefined;
    var text_bin: erts.ErlNifBinary = undefined;
    if (erts.enif_get_int(env, argv[0], &fgs_type) == 0) return erts.badarg(env);
    if (erts.enif_inspect_binary(env, argv[1], &title_bin) == 0) return erts.badarg(env);
    if (erts.enif_inspect_binary(env, argv[2], &text_bin) == 0) return erts.badarg(env);
    var title_buf: [256]u8 = undefined;
    var text_buf: [256]u8 = undefined;
    const title = cString(title_bin, &title_buf) orelse return erts.badarg(env);
    const text = cString(text_bin, &text_buf) orelse return erts.badarg(env);

    if (g_bg_cls == null or g_bg.keep_alive == null) return erts.errorTuple(env, erts.atom(env, "bridge_not_registered"));
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.errorTuple(env, erts.atom(env, "no_jni_env"));
    defer detachIfAttached(attached);
    const jtitle = jni.newStringUTF(jenv, title);
    const jtext = jni.newStringUTF(jenv, text);
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_bg_cls, g_bg.keep_alive, @as(jni.JInt, fgs_type), jtitle, jtext);
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, jtitle);
    jni.deleteLocalRef(jenv, jtext);
    // 0 = started; anything else is one of the status error codes.
    return if (code == 0) erts.ok(env) else statusTerm(env, code);
}

fn nif_background_stop(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bg_cls == null or g_bg.stop == null) return erts.ok(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.ok(env);
    jenv.*.CallStaticVoidMethod.?(jenv, g_bg_cls, g_bg.stop);
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return erts.ok(env);
}

// Maps MobBackgroundBridge codes (STATUS_* there) to terms.
fn statusTerm(env: ?*erts.ErlNifEnv, code: jni.JInt) erts.ERL_NIF_TERM {
    return switch (code) {
        0 => erts.atom(env, "idle"),
        1 => erts.atom(env, "running"),
        2 => erts.errorTuple(env, erts.atom(env, "no_activity")),
        3 => erts.errorTuple(env, erts.atom(env, "service_not_declared")),
        4 => erts.errorTuple(env, erts.atom(env, "service_type_unsupported")),
        5 => erts.errorTuple(env, erts.atom(env, "status_failed")),
        6 => erts.errorTuple(env, erts.atom(env, "type_not_declared")),
        7 => erts.errorTuple(env, erts.atom(env, "no_type_permission")),
        8 => erts.errorTuple(env, erts.atom(env, "start_not_allowed")),
        9 => erts.errorTuple(env, erts.atom(env, "start_failed")),
        else => erts.errorTuple(env, erts.makeTuple(env, .{ erts.atom(env, "unknown_status"), erts.enif_make_int64(env, code) })),
    };
}

// Read-only status. Like keep_alive, it reports a missing bridge, so
// MobBackground.SelfTest can tell a registered bridge from an unregistered one.
fn nif_background_status(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bg_cls == null or g_bg.status == null) return erts.errorTuple(env, erts.atom(env, "bridge_not_registered"));
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.errorTuple(env, erts.atom(env, "no_jni_env"));
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_bg_cls, g_bg.status);
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return statusTerm(env, code);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "background_keep_alive", .arity = 3, .fptr = nif_background_keep_alive, .flags = 0 },
    .{ .name = "background_stop", .arity = 0, .fptr = nif_background_stop, .flags = 0 },
    .{ .name = "background_status", .arity = 0, .fptr = nif_background_status, .flags = 0 },
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
