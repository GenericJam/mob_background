/* mob_background_nif — iOS background-keep-alive plugin NIF (Objective-C).
 *
 * Starts/stops a silent AVAudioEngine session so iOS keeps the app running
 * when the screen locks. The session uses MixWithOthers so it does not
 * interrupt or duck the user's music or the app's own Mob.Audio playback.
 *
 * Coexistence with Mob.Audio recording/playback:
 *   - Playback: MixWithOthers on both sides — they mix, silence is inaudible.
 *   - Recording: start_recording switches the session category to PlayAndRecord,
 *     which sends an interruption to this engine. The engine stops, but the
 *     recording itself keeps the app alive. When recording ends, the session
 *     sends InterruptionTypeEnded and this engine restarts automatically.
 *
 * Requires UIBackgroundModes: [audio] in the app's Info.plist.
 *
 * Compiled as ObjC (-fobjc-arc) by the plugin C-NIF path (manifest lang:
 * :objc). Registered as the Erlang module mob_background_nif via ERL_NIF_INIT.
 */
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>

static AVAudioEngine *g_keep_alive_engine = nil;
static AVAudioPlayerNode *g_keep_alive_player = nil;
static BOOL g_keep_alive_active = NO; // user intent: should be running
static id g_keep_alive_interruption_observer =
    nil; // token from addObserverForName, needed for removeObserver

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
    // takes down the BEAM scheduler thread.
    AVAudioFormat *fmt = [g_keep_alive_engine.mainMixerNode outputFormatForBus:0];
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
    NSLog(@"[mob] keep_alive engine running (sampleRate=%.0f, channels=%u)", fmt.sampleRate,
          (unsigned)fmt.channelCount);
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

static ERL_NIF_TERM nif_background_keep_alive(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  // Async so the BEAM scheduler isn't blocked while AVFoundation initialises
  // (which can throw an NSException and take down the scheduler thread).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_keep_alive_active)
      return; // idempotent
    g_keep_alive_active = YES;

    // Restart engine after audio session interruptions (e.g. recording ends,
    // phone call ends). InterruptionTypeEnded fires when the session is ours
    // again; we reconfigure and resume the silence loop.
    // Stash the returned token — block-based observers must be removed
    // by their token, not by name (passing nil to removeObserver: is
    // a no-op for the block API).
    g_keep_alive_interruption_observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  if (!g_keep_alive_active)
                    return;
                  AVAudioSessionInterruptionType type =
                      [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                  if (type == AVAudioSessionInterruptionTypeBegan) {
                    keep_alive_stop_engine();
                  } else {
                    // InterruptionTypeEnded — real audio finished, reclaim the session.
                    keep_alive_start_engine();
                  }
                }];

    keep_alive_start_engine();
  });
  return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_background_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  (void)argv;
  dispatch_async(dispatch_get_main_queue(), ^{
    g_keep_alive_active = NO;
    if (g_keep_alive_interruption_observer) {
      [[NSNotificationCenter defaultCenter] removeObserver:g_keep_alive_interruption_observer];
      g_keep_alive_interruption_observer = nil;
    }
    keep_alive_stop_engine();
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];
  });
  return enif_make_atom(env, "ok");
}

static ErlNifFunc nif_funcs[] = {
    {"background_keep_alive", 0, nif_background_keep_alive, 0},
    {"background_stop", 0, nif_background_stop, 0},
};

ERL_NIF_INIT(mob_background_nif, nif_funcs, NULL, NULL, NULL, NULL)
