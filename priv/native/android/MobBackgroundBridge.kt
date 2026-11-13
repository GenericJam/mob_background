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
// android.manifest_application_snippets (dataSync), unless the host declares
// it itself (another type, e.g. mediaPlayback).
package io.mob.background

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import java.lang.ref.WeakReference

object MobBackgroundBridge : io.mob.plugin.MobActivityAware {
    // background_status() and background_keep_alive() codes, mapped to atoms by
    // mob_background_nif.zig.
    private const val STATUS_IDLE = 0
    private const val STATUS_RUNNING = 1
    private const val STATUS_NO_ACTIVITY = 2
    private const val STATUS_SERVICE_NOT_DECLARED = 3
    private const val STATUS_SERVICE_TYPE_UNSUPPORTED = 4
    private const val STATUS_FAILED = 5
    private const val STATUS_TYPE_NOT_DECLARED = 6
    private const val STATUS_NO_TYPE_PERMISSION = 7
    private const val STATUS_START_NOT_ALLOWED = 8
    private const val STATUS_START_FAILED = 9

    // background_keep_alive() success.
    private const val STARTED = 0

    private const val TAG = "MobBackground"

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
                    info.foregroundServiceType and BeamForegroundService.SUPPORTED_TYPES == 0 ->
                    STATUS_SERVICE_TYPE_UNSUPPORTED
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

    // The FOREGROUND_SERVICE_<TYPE> permission Android 14 requires for a type.
    private fun typePermission(type: Int): String? = when (type) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC -> "android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK -> "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"
        else -> null
    }

    // Starts (or updates: a second call with another text replaces the
    // notification) the foreground service with `type` (a ServiceInfo
    // FOREGROUND_SERVICE_TYPE_* in SUPPORTED_TYPES) and the notification's
    // title and text ("" = app name / "Running in background"). Checks first
    // what Android would otherwise refuse inside the service, where it can't
    // be reported: the <service> must declare the type and, on API 34+, the
    // app must hold its FOREGROUND_SERVICE_<TYPE> permission. Never throws.
    @JvmStatic
    fun background_keep_alive(type: Int, title: String, text: String): Int = try {
        val activity = activityRef?.get()
        val info = activity?.let { serviceInfo(it) }
        when {
            activity == null -> STATUS_NO_ACTIVITY
            info == null -> STATUS_SERVICE_NOT_DECLARED
            Build.VERSION.SDK_INT >= 29 && info.foregroundServiceType and type == 0 -> STATUS_TYPE_NOT_DECLARED
            Build.VERSION.SDK_INT >= 34 &&
                activity.checkSelfPermission(typePermission(type) ?: "") != PackageManager.PERMISSION_GRANTED ->
                STATUS_NO_TYPE_PERMISSION
            else -> {
                val intent = Intent(activity, BeamForegroundService::class.java).apply {
                    action = BeamForegroundService.ACTION_START
                    putExtra(BeamForegroundService.EXTRA_TYPE, type)
                    putExtra(BeamForegroundService.EXTRA_TITLE, title)
                    putExtra(BeamForegroundService.EXTRA_TEXT, text)
                }
                if (Build.VERSION.SDK_INT >= 26) {
                    activity.startForegroundService(intent)
                } else {
                    activity.startService(intent)
                }
                STARTED
            }
        }
    } catch (e: Throwable) {
        // ForegroundServiceStartNotAllowedException (API 31+): started while the
        // app is in the background and not exempt.
        if (Build.VERSION.SDK_INT >= 31 && e is android.app.ForegroundServiceStartNotAllowedException) {
            Log.w(TAG, "keep_alive refused: the app is in the background", e)
            STATUS_START_NOT_ALLOWED
        } else {
            Log.w(TAG, "keep_alive failed", e)
            STATUS_START_FAILED
        }
    }

    @JvmStatic
    fun background_stop() {
        val activity = activityRef?.get() ?: return
        val intent = Intent(activity, BeamForegroundService::class.java).apply {
            action = BeamForegroundService.ACTION_STOP
        }
        try {
            activity.startService(intent)
        } catch (_: IllegalStateException) {
            // Not running and the app is in the background: nothing to stop.
        }
    }
}
