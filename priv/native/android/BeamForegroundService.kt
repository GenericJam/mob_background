package io.mob.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

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
 * A foreground <service> must be a host-package class declared in the host's
 * AndroidManifest.xml; this file ships in the plugin's priv/ so you can copy it
 * into your app's host package. See the MobBackground moduledoc for the manifest
 * <service> snippet.
 */
class BeamForegroundService : Service() {

    companion object {
        private const val NOTIF_ID      = 9820
        private const val CHANNEL_ID    = "mob_beam_fg"
        const val ACTION_START = "mob.beam.START"
        const val ACTION_STOP  = "mob.beam.STOP"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }
        ensureChannel()
        startForeground(NOTIF_ID, buildNotification())
        return START_STICKY
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
