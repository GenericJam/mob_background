//! mob_background_nif — Android typed foreground-service ZIG plugin NIF.
//!
//! Bridges to the plugin-owned Kotlin object `io.mob.background.MobBackgroundBridge`,
//! which drives `BeamForegroundService` in `dataSync` (mode = 0), `microphone`
//! (mode = 1), or `mediaPlayback` (mode = 2) with dynamic notifications and
//! action buttons.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Registration: the JVM calls
//! `Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv, cls)` at
//! startup (MobPluginBootstrap.registerAll -> register()); that thunk caches
//! the bridge jclass, `java/lang/String` jclass, and all 5 static method IDs.
//! Action taps and asynchronous failures arrive from Kotlin through the exported
//! `nativeAction` and `nativeFailed` JNI thunks.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── ERTS functions not declared in mob_erts.zig ──────────────────────────
const ErlNifResourceType = opaque {};
const ErlNifMonitor = opaque {};

const ErlNifResourceDtor = ?*const fn (?*erts.ErlNifEnv, ?*anyopaque) callconv(.c) void;
const ErlNifResourceStop = ?*const fn (?*erts.ErlNifEnv, ?*anyopaque, c_int, c_int) callconv(.c) void;
const ErlNifResourceDown = ?*const fn (?*erts.ErlNifEnv, ?*anyopaque, *erts.ErlNifPid, ?*ErlNifMonitor) callconv(.c) void;
const ErlNifResourceDynCall = ?*const fn (?*erts.ErlNifEnv, ?*anyopaque, ?*anyopaque) callconv(.c) void;

const ErlNifResourceTypeInit = extern struct {
    dtor: ErlNifResourceDtor = null,
    stop: ErlNifResourceStop = null,
    down: ErlNifResourceDown = null,
    members: c_int = 3,
    dyncall: ErlNifResourceDynCall = null,
};

const ERL_NIF_RT_CREATE: c_int = 1;

extern fn enif_open_resource_type_x(
    env: ?*erts.ErlNifEnv,
    name_str: [*:0]const u8,
    init: *const ErlNifResourceTypeInit,
    flags: c_int,
    tried: ?*c_int,
) ?*ErlNifResourceType;
extern fn enif_alloc_resource(rt: *ErlNifResourceType, size: usize) ?*anyopaque;
extern fn enif_release_resource(obj: ?*anyopaque) void;
extern fn enif_monitor_process(
    env: ?*erts.ErlNifEnv,
    obj: ?*anyopaque,
    pid: *const erts.ErlNifPid,
    mon: ?*ErlNifMonitor,
) c_int;
extern fn enif_make_existing_atom_len(
    env: ?*erts.ErlNifEnv,
    name: [*]const u8,
    len: usize,
    atom_out: *erts.ERL_NIF_TERM,
    enc: erts.ErlNifCharEncoding,
) c_int;
extern fn enif_is_empty_list(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM) c_int;

// ── Limits & mode mapping (must match MobBackground / MobBackgroundBridge) ─
const MODE_DATA_SYNC: c_int = 0;
const MODE_MICROPHONE: c_int = 1;
const MODE_MEDIA_PLAYBACK: c_int = 2;

const MAX_TEXT_BYTES: usize = 1024;
const MAX_ACTIONS: usize = 3;
const MAX_ACTION_ID_BYTES: usize = 255;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const BgMethods = struct {
    keep_alive: jni.JMethodID = null,
    stop: jni.JMethodID = null,
    status: jni.JMethodID = null,
    start: jni.JMethodID = null,
    update: jni.JMethodID = null,
};

var g_methods: BgMethods = .{};
var g_bg_cls: jni.JClass = null;
var g_string_cls: jni.JClass = null;

// ── Owner monitor + session state (guarded by g_bg_lock) ─────────────────
const BgWatch = extern struct {
    generation: u64,
};

const StoredAction = struct {
    id_len: usize = 0,
    id: [MAX_ACTION_ID_BYTES]u8 = undefined,
    label_len: usize = 0,
    label: [MAX_TEXT_BYTES]u8 = undefined,
};

const StoredNotice = struct {
    valid: bool = false,
    title_len: usize = 0,
    title: [MAX_TEXT_BYTES]u8 = undefined,
    text_len: usize = 0,
    text: [MAX_TEXT_BYTES]u8 = undefined,
    action_count: usize = 0,
    actions: [MAX_ACTIONS]StoredAction = @splat(.{}),
};

const BgState = struct {
    running: bool = false,
    mode: c_int = MODE_DATA_SYNC,
    has_owner: bool = false,
    owner: erts.ErlNifPid = .{ .pid = 0 },
    // Monitors `owner`: when it exits the service stops so the notification
    // never outlives the process receiving its buttons. `generation` bumps on
    // every start, stop, or failure; stale down callbacks are ignored.
    watch: ?*anyopaque = null,
    generation: u64 = 0,
    last: StoredNotice = .{},
};

var g_bg_lock: ?*erts.ErlNifMutex = null;
var g_watch_type: ?*ErlNifResourceType = null;
var g_bg: BgState = .{};

// ── Parsed notice input (stack-allocated view over BEAM terms) ────────────
const NoticeInput = struct {
    title: []const u8,
    text: []const u8,
    action_count: usize = 0,
    action_ids: [MAX_ACTIONS][MAX_ACTION_ID_BYTES + 1]u8 = undefined,
    action_id_lens: [MAX_ACTIONS]usize = .{ 0, 0, 0 },
    action_labels: [MAX_ACTIONS][]const u8 = .{ "", "", "" },
};

// ── JNI vtable helpers (for slots left opaque in mob_zig.zig) ────────────
fn clearPendingException(jenv: *jni.JNIEnv) bool {
    const exception_occurred: *align(1) const fn (*jni.JNIEnv) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.ExceptionOccurred.?);
    const thrown = exception_occurred(jenv);
    if (thrown == null) return false;
    jni.exceptionClear(jenv);
    jni.deleteLocalRef(jenv, thrown);
    return true;
}

fn pushLocalFrame(jenv: *jni.JNIEnv, capacity: jni.JInt) jni.JInt {
    const push_fn: *align(1) const fn (*jni.JNIEnv, jni.JInt) callconv(.c) jni.JInt =
        @ptrCast(jenv.*.PushLocalFrame.?);
    return push_fn(jenv, capacity);
}

fn popLocalFrame(jenv: *jni.JNIEnv, result: jni.JObject) jni.JObject {
    const pop_fn: *align(1) const fn (*jni.JNIEnv, jni.JObject) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.PopLocalFrame.?);
    return pop_fn(jenv, result);
}

fn makeJavaString(jenv: *jni.JNIEnv, bytes: []const u8) jni.JString {
    // Elixir strings are standard UTF-8 (emoji outside BMP); NewStringUTF uses
    // modified UTF-8 and corrupts non-BMP codepoints, so encode as UTF-16.
    var units: [MAX_TEXT_BYTES]u16 = undefined;
    if (bytes.len > units.len) return null;
    const len = std.unicode.utf8ToUtf16Le(&units, bytes) catch return null;
    const new_string: *align(1) const fn (*jni.JNIEnv, [*]const u16, jni.JSize) callconv(.c) jni.JString =
        @ptrCast(jenv.*.NewString.?);
    const str = new_string(jenv, &units, @intCast(len));
    if (str == null) _ = clearPendingException(jenv);
    return str;
}

fn makeJavaStringArray(
    jenv: *jni.JNIEnv,
    count: usize,
    items: [MAX_ACTIONS][]const u8,
) jni.JObject {
    const str_cls = g_string_cls orelse return null;
    const new_object_array: *align(1) const fn (*jni.JNIEnv, jni.JSize, jni.JClass, jni.JObject) callconv(.c) jni.JObject =
        @ptrCast(jenv.*.NewObjectArray.?);
    const set_object_array_element: *align(1) const fn (*jni.JNIEnv, jni.JObject, jni.JSize, jni.JObject) callconv(.c) void =
        @ptrCast(jenv.*.SetObjectArrayElement.?);

    const arr = new_object_array(jenv, @intCast(count), str_cls, null);
    if (arr == null) {
        _ = clearPendingException(jenv);
        return null;
    }

    for (0..count) |i| {
        const jstr = makeJavaString(jenv, items[i]);
        if (jstr == null) {
            jni.deleteLocalRef(jenv, arr);
            return null;
        }
        set_object_array_element(jenv, arr, @intCast(i), jstr);
        jni.deleteLocalRef(jenv, jstr);
        if (clearPendingException(jenv)) {
            jni.deleteLocalRef(jenv, arr);
            return null;
        }
    }
    return arr;
}

fn getStringLength(jenv: *jni.JNIEnv, str: jni.JString) jni.JSize {
    const len_fn: *align(1) const fn (*jni.JNIEnv, jni.JString) callconv(.c) jni.JSize =
        @ptrCast(jenv.*.GetStringLength.?);
    return len_fn(jenv, str);
}

fn getStringChars(jenv: *jni.JNIEnv, str: jni.JString) ?[*]const u16 {
    const chars_fn: *align(1) const fn (*jni.JNIEnv, jni.JString, ?*jni.JBoolean) callconv(.c) ?[*]const u16 =
        @ptrCast(jenv.*.GetStringChars.?);
    return chars_fn(jenv, str, null);
}

fn releaseStringChars(jenv: *jni.JNIEnv, str: jni.JString, chars: [*]const u16) void {
    const rel_fn: *align(1) const fn (*jni.JNIEnv, jni.JString, [*]const u16) callconv(.c) void =
        @ptrCast(jenv.*.ReleaseStringChars.?);
    rel_fn(jenv, str, chars);
}

// ── Thread-attach helper (mirror mob-core) ───────────────────────────────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

// ── nativeRegister thunk — cache the bridge jclass + method ids ──────────
// Runs on the Android main thread during MainActivity.onCreate (before nifLoad).
export fn Java_io_mob_background_MobBackgroundBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    if (g_bg_cls != null) return;

    const str_cls = jni.findClass(jenv, "java/lang/String");
    if (str_cls != null) {
        g_string_cls = jni.newGlobalRef(jenv, str_cls);
        jni.deleteLocalRef(jenv, str_cls);
    } else {
        _ = clearPendingException(jenv);
    }

    // Clear NoSuchMethodError on lookup failure so an exception never leaks into
    // any later BEAM-thread JNI call.
    g_methods.keep_alive = jni.getStaticMethodID(jenv, cls, "background_keep_alive", "()Z");
    if (g_methods.keep_alive == null) jni.exceptionClear(jenv);
    g_methods.stop = jni.getStaticMethodID(jenv, cls, "background_stop", "()V");
    if (g_methods.stop == null) jni.exceptionClear(jenv);
    g_methods.status = jni.getStaticMethodID(jenv, cls, "background_status", "()I");
    if (g_methods.status == null) jni.exceptionClear(jenv);
    g_methods.start = jni.getStaticMethodID(
        jenv,
        cls,
        "start",
        "(ILjava/lang/String;Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;)Ljava/lang/String;",
    );
    if (g_methods.start == null) jni.exceptionClear(jenv);
    g_methods.update = jni.getStaticMethodID(
        jenv,
        cls,
        "update",
        "(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;)V",
    );
    if (g_methods.update == null) jni.exceptionClear(jenv);

    g_bg_cls = jni.newGlobalRef(jenv, cls);
}

// ── Owner monitor + state helpers (caller holds g_bg_lock) ───────────────
fn bgForgetLocked() void {
    g_bg.generation +%= 1;
    if (g_bg.watch) |w| {
        enif_release_resource(w);
        g_bg.watch = null;
    }
    g_bg.has_owner = false;
}

fn bgWatchLocked(env: ?*erts.ErlNifEnv, owner: *const erts.ErlNifPid) bool {
    bgForgetLocked();
    const rt = g_watch_type orelse return false;
    const raw = enif_alloc_resource(rt, @sizeOf(BgWatch)) orelse return false;
    const w: *BgWatch = @ptrCast(@alignCast(raw));
    w.generation = g_bg.generation;
    if (enif_monitor_process(env, raw, owner, null) != 0) {
        enif_release_resource(raw);
        return false;
    }
    g_bg.watch = raw;
    g_bg.has_owner = true;
    return true;
}

fn bgStopLocked(jenv: ?*jni.JNIEnv) void {
    if (jenv) |j| {
        if (g_bg_cls != null and g_methods.stop != null) {
            j.*.CallStaticVoidMethod.?(j, g_bg_cls, g_methods.stop);
            _ = clearPendingException(j);
        }
    }
    g_bg.running = false;
    g_bg.last.valid = false;
    bgForgetLocked();
}

// The owner died: stop the service, unless it was stopped or restarted since.
// Runs on a detached thread because an ERTS down callback must not call JNI.
fn bgOwnerDownMain(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const generation: u64 = @intFromPtr(arg);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached);
    const lock = g_bg_lock orelse {
        detachIfAttached(attached);
        return null;
    };
    erts.enif_mutex_lock(lock);
    if (g_bg.running and g_bg.has_owner and generation == g_bg.generation) {
        _ = jni.__android_log_write(
            jni.ANDROID_LOG_INFO,
            "MobBackground",
            "background owner died: stopping service",
        );
        bgStopLocked(jenv);
    }
    erts.enif_mutex_unlock(lock);
    detachIfAttached(attached);
    return null;
}

fn bgOwnerDown(
    env: ?*erts.ErlNifEnv,
    obj: ?*anyopaque,
    pid: *erts.ErlNifPid,
    mon: ?*ErlNifMonitor,
) callconv(.c) void {
    _ = env;
    _ = pid;
    _ = mon;
    const w: *const BgWatch = @ptrCast(@alignCast(obj orelse return));
    var tid: jni.PthreadT = 0;
    const arg: ?*anyopaque = @ptrFromInt(@as(usize, @truncate(w.generation)));
    if (jni.pthread_create(&tid, null, bgOwnerDownMain, arg) != 0) {
        _ = jni.__android_log_write(
            jni.ANDROID_LOG_ERROR,
            "MobBackground",
            "background owner died, and no thread to stop the service",
        );
        return;
    }
    _ = jni.pthread_detach(tid);
}

// ── Inbound JNI thunks from Kotlin ───────────────────────────────────────
fn decodeActionId(jenv: *jni.JNIEnv, jid: jni.JString, utf8_buf: *[MAX_ACTION_ID_BYTES * 3]u8) usize {
    if (jid == null) return 0;
    const len = getStringLength(jenv, jid);
    if (len <= 0 or len > MAX_ACTION_ID_BYTES) return 0;
    const chars = getStringChars(jenv, jid) orelse {
        _ = clearPendingException(jenv);
        return 0;
    };
    defer releaseStringChars(jenv, jid, chars);
    const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, chars[0..@intCast(len)]) catch return 0;
    if (utf8_len > MAX_ACTION_ID_BYTES) return 0;
    return utf8_len;
}

export fn Java_io_mob_background_MobBackgroundBridge_nativeAction(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    jid: jni.JString,
) callconv(.c) jni.JBoolean {
    _ = cls;
    var utf8_buf: [MAX_ACTION_ID_BYTES * 3]u8 = undefined;
    const utf8_len = decodeActionId(jenv, jid, &utf8_buf);

    const lock = g_bg_lock orelse return 0;
    erts.enif_mutex_lock(lock);
    defer erts.enif_mutex_unlock(lock);

    if (!g_bg.running) return 0;

    var delivered = false;
    if (utf8_len > 0 and g_bg.has_owner) {
        if (erts.enif_alloc_env()) |msg_env| {
            defer erts.enif_free_env(msg_env);
            // Never allocate a new atom from Java input.
            var id_atom: erts.ERL_NIF_TERM = 0;
            if (enif_make_existing_atom_len(msg_env, &utf8_buf, utf8_len, &id_atom, erts.ERL_NIF_UTF8) != 0) {
                const payload = erts.makeTuple(msg_env, .{ erts.atom(msg_env, "action"), id_atom });
                const msg = erts.makeTuple(msg_env, .{ erts.atom(msg_env, "mob_background"), payload });
                delivered = erts.enif_send(null, &g_bg.owner, msg_env, msg) != 0;
            }
        }
    }

    // BeamForegroundService stops itself whenever nativeAction returns false
    // (e.g. an owner-less keep_alive session updated with buttons, or an owner
    // that exited before its monitor ran). Clear NIF state in lockstep so
    // status/keep_alive/update never treat a stopped service as running.
    if (!delivered) {
        g_bg.running = false;
        g_bg.last.valid = false;
        bgForgetLocked();
    }
    return if (delivered) 1 else 0;
}

export fn Java_io_mob_background_MobBackgroundBridge_nativeFailed(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    jreason: jni.JString,
) callconv(.c) void {
    _ = cls;
    var is_timeout = false;
    if (jreason != null) {
        if (jni.getStringUTFChars(jenv, jreason)) |cstr| {
            defer jni.releaseStringUTFChars(jenv, jreason, cstr);
            const slice = cstr[0..std.mem.len(cstr)];
            is_timeout = std.mem.eql(u8, slice, "timeout");
        } else {
            _ = clearPendingException(jenv);
        }
    }

    const lock = g_bg_lock orelse return;
    erts.enif_mutex_lock(lock);
    defer erts.enif_mutex_unlock(lock);

    if (!g_bg.running) return;

    if (g_bg.has_owner) {
        if (erts.enif_alloc_env()) |msg_env| {
            defer erts.enif_free_env(msg_env);
            const reason_atom = if (is_timeout)
                erts.atom(msg_env, "timeout")
            else
                erts.atom(msg_env, "foreground_refused");
            const payload = erts.makeTuple(msg_env, .{ erts.atom(msg_env, "error"), reason_atom });
            const msg = erts.makeTuple(msg_env, .{ erts.atom(msg_env, "mob_background"), payload });
            _ = erts.enif_send(null, &g_bg.owner, msg_env, msg);
        }
    }

    g_bg.running = false;
    g_bg.last.valid = false;
    bgForgetLocked();
}

// ── Term parsing + stored-notice comparison ──────────────────────────────
fn validUtf8(bytes: []const u8) bool {
    var tmp: [MAX_TEXT_BYTES]u16 = undefined;
    if (bytes.len > tmp.len) return false;
    _ = std.unicode.utf8ToUtf16Le(&tmp, bytes) catch return false;
    return true;
}

fn parseNotice(
    env: ?*erts.ErlNifEnv,
    title_term: erts.ERL_NIF_TERM,
    text_term: erts.ERL_NIF_TERM,
    actions_term: erts.ERL_NIF_TERM,
) ?NoticeInput {
    var title_bin: erts.ErlNifBinary = undefined;
    var text_bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, title_term, &title_bin) == 0) return null;
    if (erts.enif_inspect_binary(env, text_term, &text_bin) == 0) return null;
    if (title_bin.size > MAX_TEXT_BYTES or text_bin.size > MAX_TEXT_BYTES) return null;

    const title_slice = title_bin.data[0..title_bin.size];
    const text_slice = text_bin.data[0..text_bin.size];
    if (!validUtf8(title_slice) or !validUtf8(text_slice)) return null;

    var out: NoticeInput = .{
        .title = title_slice,
        .text = text_slice,
    };

    var cur = actions_term;
    var head: erts.ERL_NIF_TERM = 0;
    var tail: erts.ERL_NIF_TERM = 0;
    while (erts.enif_get_list_cell(env, cur, &head, &tail) != 0) : (cur = tail) {
        if (out.action_count >= MAX_ACTIONS) return null;

        var arity: c_int = 0;
        var elems: [*]const erts.ERL_NIF_TERM = undefined;
        if (erts.enif_get_tuple(env, head, &arity, &elems) == 0 or arity != 2) return null;

        const idx = out.action_count;
        out.action_ids[idx] = @splat(0);
        if (erts.enif_get_atom(
            env,
            elems[0],
            &out.action_ids[idx],
            out.action_ids[idx].len,
            erts.ERL_NIF_UTF8,
        ) == 0) return null;

        const id_len = jni.zLen(&out.action_ids[idx]);
        if (id_len == 0 or id_len > MAX_ACTION_ID_BYTES) return null;
        const id_slice = out.action_ids[idx][0..id_len];
        if (std.mem.eql(u8, id_slice, "nil") or
            std.mem.eql(u8, id_slice, "true") or
            std.mem.eql(u8, id_slice, "false")) return null;
        if (!validUtf8(id_slice)) return null;

        for (0..idx) |prev| {
            if (std.mem.eql(u8, out.action_ids[prev][0..out.action_id_lens[prev]], id_slice)) {
                return null;
            }
        }

        var label_bin: erts.ErlNifBinary = undefined;
        if (erts.enif_inspect_binary(env, elems[1], &label_bin) == 0) return null;
        if (label_bin.size > MAX_TEXT_BYTES) return null;
        const label_slice = label_bin.data[0..label_bin.size];
        if (!validUtf8(label_slice)) return null;

        out.action_id_lens[idx] = id_len;
        out.action_labels[idx] = label_slice;
        out.action_count += 1;
    }

    if (enif_is_empty_list(env, cur) == 0) return null;
    return out;
}

fn noticeEquals(stored: *const StoredNotice, input: *const NoticeInput) bool {
    if (!stored.valid) return false;
    if (!std.mem.eql(u8, stored.title[0..stored.title_len], input.title)) return false;
    if (!std.mem.eql(u8, stored.text[0..stored.text_len], input.text)) return false;
    if (stored.action_count != input.action_count) return false;
    for (0..input.action_count) |i| {
        const a = &stored.actions[i];
        const id_slice = input.action_ids[i][0..input.action_id_lens[i]];
        if (!std.mem.eql(u8, a.id[0..a.id_len], id_slice)) return false;
        if (!std.mem.eql(u8, a.label[0..a.label_len], input.action_labels[i])) return false;
    }
    return true;
}

fn rememberNotice(input: *const NoticeInput) void {
    g_bg.last.valid = true;
    g_bg.last.title_len = input.title.len;
    if (input.title.len > 0) @memcpy(g_bg.last.title[0..input.title.len], input.title);
    g_bg.last.text_len = input.text.len;
    if (input.text.len > 0) @memcpy(g_bg.last.text[0..input.text.len], input.text);
    g_bg.last.action_count = input.action_count;
    for (0..input.action_count) |i| {
        const id_len = input.action_id_lens[i];
        const label_len = input.action_labels[i].len;
        g_bg.last.actions[i].id_len = id_len;
        if (id_len > 0) @memcpy(g_bg.last.actions[i].id[0..id_len], input.action_ids[i][0..id_len]);
        g_bg.last.actions[i].label_len = label_len;
        if (label_len > 0) @memcpy(g_bg.last.actions[i].label[0..label_len], input.action_labels[i]);
    }
}

fn noticeActionIdSlices(input: *const NoticeInput) [MAX_ACTIONS][]const u8 {
    var slices: [MAX_ACTIONS][]const u8 = .{ "", "", "" };
    for (0..input.action_count) |i| {
        slices[i] = input.action_ids[i][0..input.action_id_lens[i]];
    }
    return slices;
}

fn startErrorTerm(env: ?*erts.ErlNifEnv, jenv: *jni.JNIEnv, err_str: jni.JString) erts.ERL_NIF_TERM {
    const cstr = jni.getStringUTFChars(jenv, err_str) orelse {
        _ = clearPendingException(jenv);
        return erts.errorTuple(env, erts.atom(env, "refused"));
    };
    defer jni.releaseStringUTFChars(jenv, err_str, cstr);

    const slice = cstr[0..std.mem.len(cstr)];
    if (std.mem.eql(u8, slice, "permission")) {
        return erts.errorTuple(env, erts.atom(env, "permission"));
    }
    if (std.mem.eql(u8, slice, "unavailable")) {
        return erts.errorTuple(env, erts.atom(env, "unavailable"));
    }
    return erts.errorTuple(env, erts.atom(env, "refused"));
}

// ── NIFs ──────────────────────────────────────────────────────────────────
fn nif_background_start(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;

    var owner: erts.ErlNifPid = .{ .pid = 0 };
    if (erts.enif_get_local_pid(env, argv[0], &owner) == 0) {
        return erts.badarg(env);
    }

    var mode: c_int = 0;
    if (erts.enif_get_int(env, argv[1], &mode) == 0 or
        (mode != MODE_DATA_SYNC and mode != MODE_MICROPHONE and mode != MODE_MEDIA_PLAYBACK))
    {
        return erts.badarg(env);
    }

    const notice = parseNotice(env, argv[2], argv[3], argv[4]) orelse return erts.badarg(env);

    if (g_bg_cls == null or g_methods.start == null or g_string_cls == null) {
        return erts.errorTuple(env, erts.atom(env, "unavailable"));
    }

    const lock = g_bg_lock orelse return erts.errorTuple(env, erts.atom(env, "unavailable"));
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.errorTuple(env, erts.atom(env, "unavailable"));
    defer detachIfAttached(attached);

    erts.enif_mutex_lock(lock);
    defer erts.enif_mutex_unlock(lock);

    if (pushLocalFrame(jenv, 16) != jni.JNI_OK) {
        _ = clearPendingException(jenv);
        return erts.errorTuple(env, erts.atom(env, "refused"));
    }
    defer _ = popLocalFrame(jenv, null);

    const jtitle = makeJavaString(jenv, notice.title);
    const jtext = makeJavaString(jenv, notice.text);
    const jids = makeJavaStringArray(jenv, notice.action_count, noticeActionIdSlices(&notice));
    const jlabels = makeJavaStringArray(jenv, notice.action_count, notice.action_labels);
    if (jtitle == null or jtext == null or jids == null or jlabels == null) {
        return erts.errorTuple(env, erts.atom(env, "refused"));
    }

    const err_obj = jenv.*.CallStaticObjectMethod.?(
        jenv,
        g_bg_cls,
        g_methods.start,
        @as(jni.JInt, mode),
        jtitle,
        jtext,
        jids,
        jlabels,
    );
    if (clearPendingException(jenv)) {
        return erts.errorTuple(env, erts.atom(env, "refused"));
    }
    if (err_obj != null) {
        return startErrorTerm(env, jenv, err_obj);
    }

    if (!bgWatchLocked(env, &owner)) {
        // Owner already died: stop the just-started service immediately.
        bgStopLocked(jenv);
        return erts.errorTuple(env, erts.atom(env, "owner_dead"));
    }
    g_bg.owner = owner;
    g_bg.running = true;
    g_bg.mode = mode;
    rememberNotice(&notice);
    return erts.ok(env);
}

fn nif_background_update(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const notice = parseNotice(env, argv[0], argv[1], argv[2]) orelse return erts.badarg(env);

    const lock = g_bg_lock orelse return erts.errorTuple(env, erts.atom(env, "not_running"));
    erts.enif_mutex_lock(lock);
    defer erts.enif_mutex_unlock(lock);

    if (!g_bg.running) return erts.errorTuple(env, erts.atom(env, "not_running"));
    if (noticeEquals(&g_bg.last, &notice)) return erts.ok(env);

    if (g_bg_cls == null or g_methods.update == null or g_string_cls == null) {
        return erts.ok(env);
    }

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.ok(env);
    defer detachIfAttached(attached);

    if (pushLocalFrame(jenv, 16) != jni.JNI_OK) {
        _ = clearPendingException(jenv);
        return erts.ok(env);
    }
    defer _ = popLocalFrame(jenv, null);

    const jtitle = makeJavaString(jenv, notice.title);
    const jtext = makeJavaString(jenv, notice.text);
    const jids = makeJavaStringArray(jenv, notice.action_count, noticeActionIdSlices(&notice));
    const jlabels = makeJavaStringArray(jenv, notice.action_count, notice.action_labels);
    if (jtitle != null and jtext != null and jids != null and jlabels != null) {
        jenv.*.CallStaticVoidMethod.?(jenv, g_bg_cls, g_methods.update, jtitle, jtext, jids, jlabels);
        if (!clearPendingException(jenv)) {
            rememberNotice(&notice);
        }
    }
    return erts.ok(env);
}

// Returns :ok on missing-cache, already-running, or failure so keep_alive/0's
// idempotent compat contract holds.
fn nif_background_keep_alive(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bg_cls == null or g_methods.keep_alive == null) return erts.ok(env);
    const lock = g_bg_lock orelse return erts.ok(env);

    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.ok(env);
    defer detachIfAttached(attached);

    erts.enif_mutex_lock(lock);
    defer erts.enif_mutex_unlock(lock);

    if (g_bg.running) return erts.ok(env);

    const started = jenv.*.CallStaticBooleanMethod.?(jenv, g_bg_cls, g_methods.keep_alive);
    if (!clearPendingException(jenv) and started != 0) {
        bgForgetLocked();
        g_bg.running = true;
        g_bg.mode = MODE_DATA_SYNC;
        g_bg.has_owner = false;
        g_bg.last.valid = false;
    }
    return erts.ok(env);
}

fn nif_background_stop(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    const lock = g_bg_lock orelse return erts.ok(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached);
    defer detachIfAttached(attached);

    erts.enif_mutex_lock(lock);
    bgStopLocked(jenv);
    erts.enif_mutex_unlock(lock);
    return erts.ok(env);
}

// Maps MobBackgroundBridge.background_status() codes (STATUS_* there) to terms.
fn statusTerm(env: ?*erts.ErlNifEnv, code: jni.JInt) erts.ERL_NIF_TERM {
    return switch (code) {
        0 => erts.atom(env, "idle"),
        1 => erts.makeTuple(env, .{ erts.atom(env, "running"), erts.atom(env, "data_sync") }),
        2 => erts.errorTuple(env, erts.atom(env, "no_activity")),
        3 => erts.errorTuple(env, erts.atom(env, "service_not_declared")),
        4 => erts.errorTuple(env, erts.atom(env, "service_not_data_sync")),
        5 => erts.errorTuple(env, erts.atom(env, "status_failed")),
        6 => erts.makeTuple(env, .{ erts.atom(env, "running"), erts.atom(env, "microphone") }),
        7 => erts.makeTuple(env, .{ erts.atom(env, "running"), erts.atom(env, "media_playback") }),
        else => erts.errorTuple(
            env,
            erts.makeTuple(env, .{ erts.atom(env, "unknown_status"), erts.enif_make_int64(env, code) }),
        ),
    };
}

// Read-only status. Unlike keep_alive/stop this reports a missing bridge
// instead of answering :ok, so MobBackground.SelfTest can tell a registered
// bridge from an unregistered one.
fn nif_background_status(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bg_cls == null or g_methods.status == null) {
        return erts.errorTuple(env, erts.atom(env, "bridge_not_registered"));
    }
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.errorTuple(env, erts.atom(env, "no_jni_env"));
    defer detachIfAttached(attached);

    const code = jenv.*.CallStaticIntMethod.?(jenv, g_bg_cls, g_methods.status);
    if (clearPendingException(jenv)) {
        return erts.errorTuple(env, erts.atom(env, "status_failed"));
    }
    return statusTerm(env, code);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = priv;
    _ = info;
    g_bg_lock = erts.enif_mutex_create("mob_background_lock");
    if (g_bg_lock == null) return -1;

    const init: ErlNifResourceTypeInit = .{
        .dtor = null,
        .stop = null,
        .down = bgOwnerDown,
        .members = 3,
        .dyncall = null,
    };
    g_watch_type = enif_open_resource_type_x(
        env,
        "mob_background_owner",
        &init,
        ERL_NIF_RT_CREATE,
        null,
    );
    if (g_watch_type == null) return -1;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "background_keep_alive", .arity = 0, .fptr = nif_background_keep_alive, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "background_stop", .arity = 0, .fptr = nif_background_stop, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "background_status", .arity = 0, .fptr = nif_background_status, .flags = 0 },
    .{ .name = "background_start", .arity = 5, .fptr = nif_background_start, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
    .{ .name = "background_update", .arity = 3, .fptr = nif_background_update, .flags = erts.ERL_NIF_DIRTY_JOB_IO_BOUND },
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
