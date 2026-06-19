// mob_background plugin — Android bridge (foreground-service keep-alive).
//
// Starts / stops the host's BeamForegroundService so the BEAM node keeps
// running when the screen locks or the app is backgrounded. The native thunk
// (nativeRegister) is exported from the sibling zig NIF mob_background_nif.zig.
//
// MobPluginBootstrap.registerAll() calls register() at startup and hands off
// the Activity (MobActivityAware) — the bridge needs an Activity Context to
// start the service.
//
// NOTE: BeamForegroundService is NOT shipped as the bridge class; a foreground
// <service> must be a host-package class declared in the host's
// AndroidManifest.xml. Its source ships alongside this file under
// priv/native/android/BeamForegroundService.kt; copy it into your host package.
package io.mob.background

import android.app.Activity
import android.content.Intent
import android.os.Build
import java.lang.ref.WeakReference

object MobBackgroundBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun background_keep_alive() {
        val activity = activityRef?.get() ?: return
        val intent = Intent(activity, BeamForegroundService::class.java).apply {
            action = BeamForegroundService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= 26) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    @JvmStatic
    fun background_stop() {
        val activity = activityRef?.get() ?: return
        val intent = Intent(activity, BeamForegroundService::class.java).apply {
            action = BeamForegroundService.ACTION_STOP
        }
        activity.startService(intent)
    }
}
