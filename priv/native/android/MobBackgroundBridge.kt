// mob_background plugin — Android bridge (foreground-service keep-alive).
//
// Starts / stops BeamForegroundService so the BEAM node keeps running when the
// screen locks or the app is backgrounded. The native thunk (nativeRegister)
// is exported from the sibling zig NIF mob_background_nif.zig.
//
// MobPluginBootstrap.registerAll() calls register() at startup and hands off
// the Activity (MobActivityAware) — the bridge needs an Activity Context to
// start the service.
//
// BeamForegroundService ships in the sibling BeamForegroundService.kt (listed
// in the manifest's android.bridge_kt, so the build copies both files into the
// host's io/mob/background/); its <service> declaration is contributed through
// android.manifest_application_snippets.
package io.mob.background

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import java.lang.ref.WeakReference

object MobBackgroundBridge : io.mob.plugin.MobActivityAware {
    // background_status() codes, mapped to atoms by mob_background_nif.zig.
    private const val STATUS_IDLE = 0
    private const val STATUS_RUNNING = 1
    private const val STATUS_NO_ACTIVITY = 2
    private const val STATUS_SERVICE_NOT_DECLARED = 3
    private const val STATUS_SERVICE_NOT_DATA_SYNC = 4
    private const val STATUS_FAILED = 5

    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // Read-only: whether keep_alive() can work in this host and whether it is
    // running. Starts nothing, changes nothing. Never throws (the NIF can't
    // check for a pending exception), so failures map to STATUS_FAILED.
    @JvmStatic
    fun background_status(): Int = try {
        val activity = activityRef?.get()
        if (activity == null) {
            STATUS_NO_ACTIVITY
        } else {
            val info = serviceInfo(activity)
            when {
                info == null -> STATUS_SERVICE_NOT_DECLARED
                Build.VERSION.SDK_INT >= 29 &&
                    info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC == 0 ->
                    STATUS_SERVICE_NOT_DATA_SYNC
                BeamForegroundService.running -> STATUS_RUNNING
                else -> STATUS_IDLE
            }
        }
    } catch (_: Throwable) {
        STATUS_FAILED
    }

    // The host manifest's <service> entry for BeamForegroundService, or null
    // when it isn't declared (startForegroundService would then start nothing).
    private fun serviceInfo(activity: Activity): ServiceInfo? {
        val component = ComponentName(activity, BeamForegroundService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                activity.packageManager.getServiceInfo(component, PackageManager.ComponentInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                activity.packageManager.getServiceInfo(component, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
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
