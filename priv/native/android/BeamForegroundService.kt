package io.mob.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the BEAM node alive when the screen is locked.
 *
 * Started via MobBackground.keep_alive/0 (via mob_background_nif's
 * background_keep_alive NIF -> MobBackgroundBridge). Stopped via
 * MobBackground.stop/0 (via background_stop NIF).
 *
 * A persistent low-priority notification is required by the OS to show a foreground
 * service — this is the price of keeping the process alive while the screen is off.
 * The notification appears in the status bar but makes no sound.
 *
 * Ships in the plugin's android.bridge_kt list, so the native build copies it
 * into the host's io/mob/background/ next to MobBackgroundBridge.kt, and the
 * manifest's android.manifest_application_snippets declares its <service>
 * (foregroundServiceType="dataSync") in the host AndroidManifest.xml.
 */
class BeamForegroundService : Service() {

    companion object {
        private const val NOTIF_ID      = 9820
        private const val CHANNEL_ID    = "mob_beam_fg"
        private const val TAG           = "MobBackground"
        const val ACTION_START = "mob.beam.START"
        const val ACTION_STOP  = "mob.beam.STOP"

        // True between a successful startForeground and stop/destroy. Read by
        // MobBackgroundBridge.background_status() (MobBackground.status/0).
        @Volatile
        var running = false
            private set
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopKeepAlive()
            return START_NOT_STICKY
        }
        ensureChannel()
        // Must match android:foregroundServiceType="dataSync" on the manifest
        // <service>. Passed explicitly rather than relying on the manifest
        // lookup; ServiceCompat drops the type below API 29, where it doesn't exist.
        ServiceCompat.startForeground(
            this, NOTIF_ID, buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        running = true
        return START_STICKY
    }

    // Android 15+ (targetSdk 35) caps dataSync foreground services at 6h per
    // 24h in the background. When the cap is hit the system calls onTimeout
    // and the service must stop within a few seconds, or the app crashes with
    // ForegroundServiceDidNotStopInTimeException. The BEAM is not notified;
    // keep_alive/0 must be called again (from the foreground) to restart.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "dataSync foreground service time limit reached (startId=$startId, fgsType=$fgsType); stopping keep-alive")
        stopKeepAlive()
    }

    // Single-argument overload (API 34+). The system calls it for
    // shortService timeouts; dataSync gets the two-argument overload above on
    // API 35+. Handled the same way so no timeout path can leave us running.
    @Deprecated("Superseded by onTimeout(Int, Int) on API 35")
    override fun onTimeout(startId: Int) {
        Log.w(TAG, "foreground service time limit reached (startId=$startId); stopping keep-alive")
        stopKeepAlive()
    }

    private fun stopKeepAlive() {
        running = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Background", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }
    }

    private fun buildNotification(): Notification {
        val appName = try {
            packageManager.getApplicationLabel(applicationInfo).toString()
        } catch (_: Exception) { "App" }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(appName)
            .setContentText("Running in background")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
