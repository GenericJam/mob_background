package io.mob.background

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Typed foreground service (`dataSync` or `microphone`) keeping the BEAM node
 * alive when the screen is locked or another app is in front.
 *
 * Driven from `mob_background_nif` via [MobBackgroundBridge]. Action button
 * presses arrive in [onStartCommand] and forward to the owner process through
 * [MobBackgroundBridge.nativeAction]; if no owner is listening, the service
 * stops itself so the notification never outlives its owner.
 *
 * Uses platform `Service.startForeground` / `stopForeground` directly rather
 * than the androidx.core compat wrapper, which needs androidx.core 1.12+ while
 * Mob hosts compile against 1.9 (MOB-505).
 *
 * Ships in the plugin's `android.bridge_kt` list, so the native build copies it
 * into the host's `io/mob/background/` next to `MobBackgroundBridge.kt`, and
 * `android.manifest_application_snippets` declares its `<service>` with
 * `foregroundServiceType="dataSync|microphone"`.
 */
class BeamForegroundService : Service() {

    companion object {
        private const val TAG = "MobBackground"
    }

    override fun onCreate() {
        super.onCreate()
        MobBackgroundBridge.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == MobBackgroundBridge.ACTION_BUTTON) {
            val id = intent.getStringExtra(MobBackgroundBridge.EXTRA_BUTTON)
            if (id != null) {
                val delivered = try {
                    MobBackgroundBridge.nativeAction(id)
                } catch (_: UnsatisfiedLinkError) {
                    false
                }
                // Nobody listening (BEAM restarted or owner died): take the notification away.
                if (!delivered) {
                    val mayStop = MobBackgroundBridge.markStoppedFromService()
                    stopForegroundRemove()
                    if (mayStop) stopSelf()
                    return START_NOT_STICKY
                }
            }
            return if (MobBackgroundBridge.isSticky()) START_STICKY else START_NOT_STICKY
        }

        val snap = MobBackgroundBridge.snapshot()
        val mode = if (intent != null && intent.hasExtra(MobBackgroundBridge.EXTRA_MODE)) {
            intent.getIntExtra(MobBackgroundBridge.EXTRA_MODE, snap.mode)
        } else {
            snap.mode
        }
        val sticky = if (intent != null && intent.hasExtra(MobBackgroundBridge.EXTRA_STICKY)) {
            intent.getBooleanExtra(MobBackgroundBridge.EXTRA_STICKY, snap.sticky)
        } else {
            snap.sticky
        }

        try {
            val notification = MobBackgroundBridge.buildForStart(this, mode)
            if (Build.VERSION.SDK_INT >= 30) {
                val fgsType = if (mode == MobBackgroundBridge.MODE_MICROPHONE) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                }
                startForeground(MobBackgroundBridge.NOTIFICATION_ID, notification, fgsType)
            } else if (Build.VERSION.SDK_INT >= 29) {
                if (mode == MobBackgroundBridge.MODE_MICROPHONE) {
                    startForeground(MobBackgroundBridge.NOTIFICATION_ID, notification)
                } else {
                    startForeground(
                        MobBackgroundBridge.NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                }
            } else {
                startForeground(MobBackgroundBridge.NOTIFICATION_ID, notification)
            }
            // A stop arrived before startForeground completed: only now, in the
            // foreground, may the service stop without crashing the app.
            if (MobBackgroundBridge.foregrounded()) {
                stopForegroundRemove()
                stopSelf()
                return START_NOT_STICKY
            }
        } catch (e: Exception) {
            // Android 14+ while-in-use rules: app moved to background, RECORD_AUDIO revoked, etc.
            Log.e(TAG, "startForeground refused", e)
            val (noMorePending, notifyFailure) = MobBackgroundBridge.startFailed()
            if (notifyFailure) {
                try {
                    MobBackgroundBridge.nativeFailed("foreground_refused")
                } catch (_: UnsatisfiedLinkError) {
                }
            }
            if (noMorePending) stopSelf()
            return START_NOT_STICKY
        }

        return if (sticky) START_STICKY else START_NOT_STICKY
    }

    // Android 15+ (targetSdk 35) caps dataSync foreground services at 6h per
    // 24h in the background; microphone has no such limit. Regardless of type,
    // Android requires stopping within a few seconds once onTimeout fires.
    override fun onTimeout(startId: Int, fgsType: Int) {
        if (Build.VERSION.SDK_INT >= 29 && fgsType == ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) {
            Log.w(TAG, "dataSync foreground service time limit reached (startId=$startId, fgsType=$fgsType); stopping")
        } else {
            Log.w(TAG, "foreground service timeout called (startId=$startId, fgsType=$fgsType); stopping")
        }
        handleTimeout()
    }

    @Deprecated("Superseded by onTimeout(Int, Int) on API 35")
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "foreground service time limit reached (startId=$startId); stopping")
        handleTimeout()
    }

    private fun handleTimeout() {
        // Leaving the foreground answers the time limit. A newer start in
        // flight owns the session now: it carries on once foregrounded, or
        // its refusal reaches its owner through startFailed().
        val mayStop = MobBackgroundBridge.markStoppedFromService()
        stopForegroundRemove()
        if (mayStop) {
            try {
                MobBackgroundBridge.nativeFailed("timeout")
            } catch (_: UnsatisfiedLinkError) {
            }
            stopSelf()
        }
    }

    private fun stopForegroundRemove() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        MobBackgroundBridge.detach(this)
        // A throttled update queued before stop may have reposted after
        // stopForeground removed the notification; cancel it here so dead buttons
        // never remain visible.
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(MobBackgroundBridge.NOTIFICATION_ID)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
