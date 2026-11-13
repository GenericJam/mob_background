package io.mob.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the BEAM node alive when the screen is locked.
 *
 * Started via MobBackground.keep_alive/1 (via mob_background_nif's
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
 * (foregroundServiceType="dataSync") in the host AndroidManifest.xml. A host
 * that keeps alive with another type declares the <service> itself (see
 * MobBackground's moduledoc); the build then leaves its declaration alone.
 */
class BeamForegroundService : Service() {

    companion object {
        private const val NOTIF_ID      = 9820
        private const val CHANNEL_ID    = "mob_beam_fg"
        private const val TAG           = "MobBackground"
        private const val DEFAULT_TEXT  = "Running in background"
        const val ACTION_START = "mob.beam.START"
        const val ACTION_STOP  = "mob.beam.STOP"
        // ACTION_START extras: the foreground service type (a ServiceInfo
        // FOREGROUND_SERVICE_TYPE_* the manifest declares) and the
        // notification's title and text ("" = the defaults).
        const val EXTRA_TYPE  = "mob.beam.TYPE"
        const val EXTRA_TITLE = "mob.beam.TITLE"
        const val EXTRA_TEXT  = "mob.beam.TEXT"

        // The types keep_alive can start with.
        const val SUPPORTED_TYPES =
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK

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
        // The bridge checked that the manifest declares the requested type. A
        // sticky restart has no intent: use the declared types keep_alive
        // supports. The type must be one the <service> declares, or Android 14+
        // throws; ServiceCompat drops it below API 29, where it doesn't exist.
        val type = intent?.getIntExtra(EXTRA_TYPE, 0)?.takeIf { it != 0 } ?: declaredType()
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotEmpty() } ?: appName()
        val text = intent?.getStringExtra(EXTRA_TEXT)?.takeIf { it.isNotEmpty() } ?: DEFAULT_TEXT
        try {
            ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(title, text), type)
        } catch (e: Exception) {
            // A start the system refuses (a missing FOREGROUND_SERVICE_* permission, a
            // background start restriction after a sticky restart) must not crash the app.
            Log.w(TAG, "startForeground(type=$type) refused; stopping keep-alive", e)
            stopKeepAlive()
            return START_NOT_STICKY
        }
        running = true
        return START_STICKY
    }

    // Android 15+ (targetSdk 35) caps dataSync foreground services at 6h per
    // 24h in the background. When the cap is hit the system calls onTimeout
    // and the service must stop within a few seconds, or the app crashes with
    // ForegroundServiceDidNotStopInTimeException. The BEAM is not notified;
    // keep_alive/1 must be called again (from the foreground) to restart.
    // mediaPlayback has no such cap.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground service time limit reached (startId=$startId, fgsType=$fgsType); stopping keep-alive")
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

    // The supported types this <service> declares; dataSync when it can't tell.
    private fun declaredType(): Int {
        if (Build.VERSION.SDK_INT < 29) return ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        val declared = try {
            val component = ComponentName(this, BeamForegroundService::class.java)
            val info = if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getServiceInfo(component, PackageManager.ComponentInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getServiceInfo(component, 0)
            }
            info.foregroundServiceType and SUPPORTED_TYPES
        } catch (_: Exception) { 0 }
        return if (declared != 0) declared else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    }

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

    private fun appName(): String = try {
        packageManager.getApplicationLabel(applicationInfo).toString()
    } catch (_: Exception) { "App" }

    private fun buildNotification(title: String, text: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
}
