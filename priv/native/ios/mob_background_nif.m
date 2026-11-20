/* mob_background_nif — iOS background-keep-alive plugin NIF (Objective-C).
 *
 * Starts/stops a silent AVAudioEngine session so iOS keeps the app running
 * when the screen locks. The session uses MixWithOthers so it does not
 * interrupt or duck the user's music or the app's own Mob.Audio playback.
 *
 * Supports both legacy keep_alive/0 (owner-less) and start/2 in :data_sync or
 * :media_playback mode (owner-monitored: owner exit stops the session); the
 * two modes run the same silent session and differ only in what status/0
 * reports. Mode :microphone returns {error, unsupported} because iOS has no
 * foreground-service equivalent; background recording is held directly by the
 * app's active recording AVAudioSession + UIBackgroundModes [audio].
 * Notifications are validated and accepted without showing persistent UI
 * (actions never fire on iOS).
 *
 * Coexistence with Mob.Audio recording/playback:
 *   - Playback: MixWithOthers on both sides — they mix, silence is inaudible.
 *   - Recording: start_recording switches the session category to
 * PlayAndRecord, which sends an interruption to this engine. The engine stops,
 * but the recording itself keeps the app alive. When recording ends, the
 * session sends InterruptionTypeEnded and this engine restarts automatically.
 *
 * Requires UIBackgroundModes: [audio] in the app's Info.plist.
 *
 * Compiled as ObjC (-fobjc-arc) by the plugin C-NIF path (manifest lang:
 * :objc). Registered as the Erlang module mob_background_nif via ERL_NIF_INIT.
 */
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>

#define MODE_DATA_SYNC 0
#define MODE_MICROPHONE 1
#define MODE_MEDIA_PLAYBACK 2
#define MAX_TEXT_BYTES 1024
#define MAX_ACTIONS 3

typedef struct {
  uint64_t generation;
} bg_watch;

static ErlNifResourceType *g_watch_type = NULL;

// Shared state read/written across BEAM scheduler threads, down callbacks, and
// the main queue.
static pthread_mutex_t g_bg_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
  BOOL active;
  int mode; // MODE_DATA_SYNC or MODE_MEDIA_PLAYBACK while active
  BOOL has_owner;
  ErlNifPid owner;
  uint64_t generation;
  bg_watch *watch;
} g_bg = {0};

// Main queue only.
static AVAudioEngine *g_keep_alive_engine = nil;
static AVAudioPlayerNode *g_keep_alive_player = nil;
static id g_keep_alive_interruption_observer = nil;
static BOOL g_audio_started = NO;

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
                          enif_make_atom(env, reason));
}

static void keep_alive_start_engine(void) {
  if (g_keep_alive_engine != nil)
    return;

  @try {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
      NSLog(@"[mob] keep_alive setCategory failed: %@", err);
      return;
    }
    if (![session setActive:YES error:&err]) {
      NSLog(@"[mob] keep_alive setActive failed: %@", err);
      return;
    }

    g_keep_alive_engine = [[AVAudioEngine alloc] init];
    g_keep_alive_player = [[AVAudioPlayerNode alloc] init];
    [g_keep_alive_engine attachNode:g_keep_alive_player];

    // Use the mixer's native format so connect: and the buffer agree —
    // a format mismatch here throws NSInvalidArgumentException, which
    // takes down the thread.
    AVAudioFormat *fmt =
        [g_keep_alive_engine.mainMixerNode outputFormatForBus:0];
    [g_keep_alive_engine connect:g_keep_alive_player
                              to:g_keep_alive_engine.mainMixerNode
                          format:fmt];

    AVAudioFrameCount frames = (AVAudioFrameCount)fmt.sampleRate;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                          frameCapacity:frames];
    buf.frameLength = frames;

    // Engine must be running before scheduleBuffer/play.
    if (![g_keep_alive_engine startAndReturnError:&err]) {
      NSLog(@"[mob] keep_alive engine start failed: %@", err);
      g_keep_alive_engine = nil;
      g_keep_alive_player = nil;
      return;
    }

    [g_keep_alive_player scheduleBuffer:buf
                                 atTime:nil
                                options:AVAudioPlayerNodeBufferLoops
                      completionHandler:nil];
    [g_keep_alive_player play];
    NSLog(@"[mob] keep_alive engine running (sampleRate=%.0f, channels=%u)",
          fmt.sampleRate, (unsigned)fmt.channelCount);
  } @catch (NSException *ex) {
    NSLog(@"[mob] keep_alive exception: %@ — %@", ex.name, ex.reason);
    g_keep_alive_engine = nil;
    g_keep_alive_player = nil;
  }
}

static void keep_alive_stop_engine(void) {
  if (g_keep_alive_player) {
    [g_keep_alive_player stop];
    g_keep_alive_player = nil;
  }
  if (g_keep_alive_engine) {
    [g_keep_alive_engine stop];
    g_keep_alive_engine = nil;
  }
}

static BOOL read_bg_active(void) {
  pthread_mutex_lock(&g_bg_lock);
  BOOL active = g_bg.active;
  pthread_mutex_unlock(&g_bg_lock);
  return active;
}

// Reconcile AVFoundation state on the main queue with g_bg.active.
static void sync_audio_state_on_main(void) {
  BOOL active = read_bg_active();

  if (active && !g_audio_started) {
    g_audio_started = YES;
    // Restart engine after audio session interruptions (e.g. recording ends,
    // phone call ends). Block-based observers must be removed by their token.
    if (g_keep_alive_interruption_observer == nil) {
      g_keep_alive_interruption_observer = [[NSNotificationCenter defaultCenter]
          addObserverForName:AVAudioSessionInterruptionNotification
                      object:nil
                       queue:[NSOperationQueue mainQueue]
                  usingBlock:^(NSNotification *note) {
                    if (!read_bg_active())
                      return;
                    AVAudioSessionInterruptionType type =
                        [note.userInfo[AVAudioSessionInterruptionTypeKey]
                            unsignedIntegerValue];
                    if (type == AVAudioSessionInterruptionTypeBegan) {
                      keep_alive_stop_engine();
                    } else {
                      keep_alive_start_engine();
                    }
                  }];
    }
    keep_alive_start_engine();
  } else if (!active && g_audio_started) {
    g_audio_started = NO;
    if (g_keep_alive_interruption_observer) {
      [[NSNotificationCenter defaultCenter]
          removeObserver:g_keep_alive_interruption_observer];
      g_keep_alive_interruption_observer = nil;
    }
    keep_alive_stop_engine();
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];
  }
}

// Caller holds g_bg_lock.
static void bg_forget_locked(void) {
  g_bg.generation++;
  if (g_bg.watch) {
    enif_release_resource(g_bg.watch);
    g_bg.watch = NULL;
  }
  g_bg.has_owner = NO;
}

// Caller holds g_bg_lock.
static BOOL bg_watch_locked(ErlNifEnv *env, const ErlNifPid *owner) {
  bg_forget_locked();
  if (!g_watch_type)
    return NO;
  bg_watch *w = enif_alloc_resource(g_watch_type, sizeof(bg_watch));
  if (!w)
    return NO;
  w->generation = g_bg.generation;
  if (enif_monitor_process(env, w, owner, NULL) != 0) {
    enif_release_resource(w);
    return NO;
  }
  g_bg.watch = w;
  g_bg.has_owner = YES;
  return YES;
}

static void bg_owner_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                          ErlNifMonitor *mon) {
  (void)env;
  (void)pid;
  (void)mon;
  bg_watch *w = (bg_watch *)obj;
  uint64_t generation = w->generation;

  pthread_mutex_lock(&g_bg_lock);
  BOOL should_stop =
      (g_bg.active && g_bg.has_owner && g_bg.generation == generation);
  if (should_stop) {
    g_bg.active = NO;
    bg_forget_locked();
  }
  pthread_mutex_unlock(&g_bg_lock);

  if (should_stop) {
    dispatch_async(dispatch_get_main_queue(), ^{
      sync_audio_state_on_main();
    });
  }
}

static BOOL validate_notice(ErlNifEnv *env, ERL_NIF_TERM title_term,
                            ERL_NIF_TERM text_term, ERL_NIF_TERM actions_term) {
  ErlNifBinary title_bin;
  ErlNifBinary text_bin;
  if (!enif_inspect_binary(env, title_term, &title_bin) ||
      !enif_inspect_binary(env, text_term, &text_bin)) {
    return NO;
  }
  if (title_bin.size > MAX_TEXT_BYTES || text_bin.size > MAX_TEXT_BYTES)
    return NO;

  ERL_NIF_TERM cur = actions_term;
  ERL_NIF_TERM head;
  ERL_NIF_TERM tail;
  char ids[MAX_ACTIONS][256];
  int count = 0;

  while (enif_get_list_cell(env, cur, &head, &tail)) {
    if (count >= MAX_ACTIONS)
      return NO;
    int arity = 0;
    const ERL_NIF_TERM *elems = NULL;
    if (!enif_get_tuple(env, head, &arity, &elems) || arity != 2)
      return NO;

    memset(ids[count], 0, sizeof(ids[count]));
    int atom_bytes = enif_get_atom(env, elems[0], ids[count],
                                   sizeof(ids[count]), ERL_NIF_UTF8);
    if (atom_bytes <= 1)
      return NO;
    if (strcmp(ids[count], "nil") == 0 || strcmp(ids[count], "true") == 0 ||
        strcmp(ids[count], "false") == 0) {
      return NO;
    }
    for (int prev = 0; prev < count; prev++) {
      if (strcmp(ids[prev], ids[count]) == 0)
        return NO;
    }

    ErlNifBinary label_bin;
    if (!enif_inspect_binary(env, elems[1], &label_bin) ||
        label_bin.size > MAX_TEXT_BYTES)
      return NO;

    count++;
    cur = tail;
  }

  return enif_is_empty_list(env, cur) != 0;
}

static ERL_NIF_TERM nif_background_start(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifPid owner;
  if (!enif_get_local_pid(env, argv[0], &owner))
    return enif_make_badarg(env);

  int mode = -1;
  if (!enif_get_int(env, argv[1], &mode) ||
      (mode != MODE_DATA_SYNC && mode != MODE_MICROPHONE &&
       mode != MODE_MEDIA_PLAYBACK)) {
    return enif_make_badarg(env);
  }

  if (!validate_notice(env, argv[2], argv[3], argv[4]))
    return enif_make_badarg(env);

  if (mode == MODE_MICROPHONE)
    return error_tuple(env, "unsupported");

  pthread_mutex_lock(&g_bg_lock);
  BOOL was_active = g_bg.active;
  if (!bg_watch_locked(env, &owner)) {
    g_bg.active = NO;
    pthread_mutex_unlock(&g_bg_lock);
    if (was_active) {
      dispatch_async(dispatch_get_main_queue(), ^{
        sync_audio_state_on_main();
      });
    }
    return error_tuple(env, "owner_dead");
  }
  g_bg.owner = owner;
  g_bg.active = YES;
  g_bg.mode = mode;
  pthread_mutex_unlock(&g_bg_lock);

  if (!was_active) {
    dispatch_async(dispatch_get_main_queue(), ^{
      sync_audio_state_on_main();
    });
  }
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_background_update(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  if (!validate_notice(env, argv[0], argv[1], argv[2]))
    return enif_make_badarg(env);

  if (!read_bg_active())
    return error_tuple(env, "not_running");

  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_background_keep_alive(ErlNifEnv *env, int argc,
                                              const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  pthread_mutex_lock(&g_bg_lock);
  BOOL was_active = g_bg.active;
  if (!was_active) {
    bg_forget_locked();
    g_bg.active = YES;
    g_bg.has_owner = NO;
    g_bg.mode = MODE_DATA_SYNC;
  }
  pthread_mutex_unlock(&g_bg_lock);

  if (!was_active) {
    dispatch_async(dispatch_get_main_queue(), ^{
      sync_audio_state_on_main();
    });
  }
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_background_stop(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  pthread_mutex_lock(&g_bg_lock);
  BOOL was_active = g_bg.active;
  g_bg.active = NO;
  bg_forget_locked();
  pthread_mutex_unlock(&g_bg_lock);

  if (was_active) {
    dispatch_async(dispatch_get_main_queue(), ^{
      sync_audio_state_on_main();
    });
  }
  return enif_make_atom(env, "ok");
}

// Read-only status: {error, no_audio_background_mode} when Info.plist lacks
// UIBackgroundModes [audio] (the silent session can't hold the app alive),
// else {running, data_sync | media_playback} / idle from the session intent.
static ERL_NIF_TERM nif_background_status(ErlNifEnv *env, int argc,
                                          const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  BOOL has_audio_mode = NO;
  @autoreleasepool {
    id modes =
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIBackgroundModes"];
    has_audio_mode = [modes isKindOfClass:[NSArray class]] &&
                     [modes containsObject:@"audio"];
  }
  if (!has_audio_mode)
    return error_tuple(env, "no_audio_background_mode");

  pthread_mutex_lock(&g_bg_lock);
  BOOL active = g_bg.active;
  int mode = g_bg.mode;
  pthread_mutex_unlock(&g_bg_lock);

  if (active) {
    return enif_make_tuple2(env, enif_make_atom(env, "running"),
                            enif_make_atom(env, mode == MODE_MEDIA_PLAYBACK
                                                    ? "media_playback"
                                                    : "data_sync"));
  }
  return enif_make_atom(env, "idle");
}

static int nif_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;
  ErlNifResourceTypeInit init = {
      .dtor = NULL,
      .stop = NULL,
      .down = bg_owner_down,
      .members = 3,
      .dyncall = NULL,
  };
  g_watch_type = enif_open_resource_type_x(env, "mob_background_owner", &init,
                                           ERL_NIF_RT_CREATE, NULL);
  if (!g_watch_type)
    return -1;
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"background_keep_alive", 0, nif_background_keep_alive, 0},
    {"background_stop", 0, nif_background_stop, 0},
    {"background_status", 0, nif_background_status, 0},
    {"background_start", 5, nif_background_start, 0},
    {"background_update", 3, nif_background_update, 0},
};

ERL_NIF_INIT(mob_background_nif, nif_funcs, nif_load, NULL, NULL, NULL)
