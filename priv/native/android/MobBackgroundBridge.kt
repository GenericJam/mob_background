// mob_background plugin — Android bridge (typed foreground service + notifications).
//
// Starts / updates / stops BeamForegroundService so the BEAM node keeps running
// when the screen locks or the app is backgrounded, in either dataSync (0) or
// microphone (1) mode. The native thunks (nativeRegister, nativeAction,
// nativeFailed) are exported from the sibling zig NIF mob_background_nif.zig.
//
// MobPluginBootstrap.registerAll() calls register() at startup and hands off
// the Activity (MobActivityAware) — the bridge needs an Activity Context to
// start the service and check permissions.
//
// BeamForegroundService ships in the sibling BeamForegroundService.kt (listed
// in the manifest's android.bridge_kt, so the build copies both files into the
// host's io/mob/background/); its <service> declaration is contributed through
// android.manifest_application_snippets.
package io.mob.background

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import java.lang.ref.WeakReference

object MobBackgroundBridge : io.mob.plugin.MobActivityAware {
    // Mode codes passed across JNI from Elixir/Zig: 0 = :data_sync, 1 = :microphone.
    const val MODE_DATA_SYNC = 0
    const val MODE_MICROPHONE = 1

    const val NOTIFICATION_ID = 9820
    const val CHANNEL_KEEP_ALIVE = "mob_beam_fg"
    const val CHANNEL_ACTIVE = "mob_background"
    const val ACTION_BUTTON = "io.mob.background.BUTTON"
    const val EXTRA_BUTTON = "button"
    const val EXTRA_MODE = "mode"
    const val EXTRA_STICKY = "sticky"

    private const val TAG = "MobBackground"
    private const val MIN_POST_MS = 250L

    // background_status() codes, mapped to atoms/tuples by mob_background_nif.zig.
    private const val STATUS_IDLE = 0
    private const val STATUS_RUNNING_DATA_SYNC = 1
    private const val STATUS_NO_ACTIVITY = 2
    private const val STATUS_SERVICE_NOT_DECLARED = 3
    private const val STATUS_SERVICE_NOT_DATA_SYNC = 4
    private const val STATUS_FAILED = 5
    private const val STATUS_RUNNING_MICROPHONE = 6

    internal data class NoticeState(
        val mode: Int = MODE_DATA_SYNC,
        val sticky: Boolean = true,
        val useActiveChannel: Boolean = false,
        val title: String = "",
        val text: String = "Running in background",
        val actionIds: Array<String> = emptyArray(),
        val actionLabels: Array<String> = emptyArray()
    )

    @Volatile private var activityRef: WeakReference<Activity>? = null
    @Volatile private var appContext: Context? = null

    private val main = Handler(Looper.getMainLooper())

    // Main thread only.
    private var service: BeamForegroundService? = null
    private var lastPost = 0L
    private var postPending = false

    // Under `lock`: notice snapshot, starts on their way to startForeground,
    // a stop waiting for them, and whether notification updates may be posted.
    private val lock = Any()
    private var state = NoticeState()
    private var pendingStarts = 0
    private var stopWanted = false
    private var live = false

    @JvmStatic external fun nativeRegister()

    /** Notification button tap; returns true if an owner process received it. */
    @JvmStatic external fun nativeAction(id: String): Boolean

    /** Asynchronous failure / system timeout; notifies owner and clears state. */
    @JvmStatic external fun nativeFailed(reason: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
        appContext = activity.applicationContext
    }

    // Read-only: whether keep-alive can work in this host and whether a session
    // is running (and in which mode). Starts nothing, changes nothing. Never
    // throws (the NIF reports throws as STATUS_FAILED).
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
                else -> synchronized(lock) {
                    val active = live || (pendingStarts > 0 && !stopWanted)
                    when {
                        !active -> STATUS_IDLE
                        state.mode == MODE_MICROPHONE -> STATUS_RUNNING_MICROPHONE
                        else -> STATUS_RUNNING_DATA_SYNC
                    }
                }
            }
        }
    } catch (_: Throwable) {
        STATUS_FAILED
    }

    // The host manifest's <service> entry for BeamForegroundService, or null
    // when it isn't declared (startForegroundService would then start nothing).
    private fun serviceInfo(context: Context): ServiceInfo? {
        val component = ComponentName(context, BeamForegroundService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.packageManager.getServiceInfo(component, PackageManager.ComponentInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getServiceInfo(component, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun serviceSupportsMode(info: ServiceInfo, mode: Int): Boolean = when (mode) {
        MODE_DATA_SYNC ->
            Build.VERSION.SDK_INT < 29 ||
                (info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC) != 0
        MODE_MICROPHONE ->
            Build.VERSION.SDK_INT < 30 ||
                (info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE) != 0
        else -> false
    }

    /**
     * Start (or retarget) an owner-bound BeamForegroundService in `mode`
     * (0 = data_sync, 1 = microphone; always START_NOT_STICKY).
     * Returns null on success, or "permission" | "refused" | "unavailable".
     */
    @JvmStatic
    fun start(
        mode: Int,
        title: String,
        text: String,
        actionIds: Array<String>,
        actionLabels: Array<String>
    ): String? {
        if (mode != MODE_DATA_SYNC && mode != MODE_MICROPHONE) return "refused"
        val activity = activityRef?.get() ?: return "unavailable"
        val info = serviceInfo(activity) ?: return "unavailable"
        if (!serviceSupportsMode(info, mode)) return "unavailable"
        if (mode == MODE_MICROPHONE &&
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            return "permission"
        }
        return startInternal(
            activity = activity,
            mode = mode,
            sticky = false,
            useActiveChannel = true,
            title = title,
            text = text,
            actionIds = actionIds,
            actionLabels = actionLabels
        )
    }

    @JvmStatic
    fun update(
        title: String,
        text: String,
        actionIds: Array<String>,
        actionLabels: Array<String>
    ) {
        synchronized(lock) {
            if (!live && !(pendingStarts > 0 && !stopWanted)) return
            state = state.copy(
                useActiveChannel = state.useActiveChannel || actionIds.isNotEmpty(),
                title = title,
                text = text,
                actionIds = actionIds.copyOf(),
                actionLabels = actionLabels.copyOf()
            )
        }
        main.post { requestPost() }
    }

    @JvmStatic
    fun background_keep_alive(): Boolean {
        synchronized(lock) {
            if (live || (pendingStarts > 0 && !stopWanted)) return true
        }
        val activity = activityRef?.get()
        if (activity == null) {
            Log.w(TAG, "keep_alive skipped: no Activity registered")
            return false
        }
        val info = serviceInfo(activity)
        if (info == null || !serviceSupportsMode(info, MODE_DATA_SYNC)) {
            Log.w(TAG, "keep_alive skipped: BeamForegroundService missing or lacks dataSync type")
            return false
        }
        val appName = try {
            activity.packageManager.getApplicationLabel(activity.applicationInfo).toString()
        } catch (_: Exception) {
            "App"
        }
        val err = startInternal(
            activity = activity,
            mode = MODE_DATA_SYNC,
            sticky = true,
            useActiveChannel = false,
            title = appName,
            text = "Running in background",
            actionIds = emptyArray(),
            actionLabels = emptyArray()
        )
        if (err != null) {
            Log.w(TAG, "keep_alive failed: $err")
            return false
        }
        return true
    }

    @JvmStatic
    fun background_stop() {
        synchronized(lock) {
            live = false
            // Never call stopService while a startForegroundService hasn't reached
            // startForeground yet: Android crashes with "did not then call Service.startForeground()".
            if (pendingStarts > 0) {
                stopWanted = true
                return
            }
        }
        // Read only thread-safe context refs here (`service` is main-thread-only).
        val ctx = appContext ?: activityRef?.get() ?: return
        ctx.stopService(Intent(ctx, BeamForegroundService::class.java))
    }

    private fun startInternal(
        activity: Activity,
        mode: Int,
        sticky: Boolean,
        useActiveChannel: Boolean,
        title: String,
        text: String,
        actionIds: Array<String>,
        actionLabels: Array<String>
    ): String? {
        val next = NoticeState(
            mode = mode,
            sticky = sticky,
            useActiveChannel = useActiveChannel,
            title = title,
            text = text,
            actionIds = actionIds.copyOf(),
            actionLabels = actionLabels.copyOf()
        )
        val prevState: NoticeState
        val prevLive: Boolean
        val prevStopWanted: Boolean
        synchronized(lock) {
            prevState = state
            prevLive = live
            prevStopWanted = stopWanted
            state = next
            pendingStarts++
            stopWanted = false
            live = false
        }
        val intent = Intent(activity, BeamForegroundService::class.java).apply {
            putExtra(EXTRA_MODE, mode)
            putExtra(EXTRA_STICKY, sticky)
        }
        return try {
            if (Build.VERSION.SDK_INT >= 26) {
                activity.startForegroundService(intent)
            } else {
                activity.startService(intent)
            }
            main.post { requestPost() }
            null
        } catch (e: Exception) {
            Log.e(TAG, "startForegroundService refused", e)
            synchronized(lock) {
                if (pendingStarts > 0) pendingStarts--
                // A stop asked for an earlier start still in flight still holds:
                // that start's foregrounded() must stop the service.
                stopWanted = stopWanted || prevStopWanted
                if (!stopWanted) {
                    state = prevState
                    live = prevLive
                }
            }
            "refused"
        }
    }

    internal fun attach(s: BeamForegroundService) {
        service = s
    }

    internal fun detach(s: BeamForegroundService) {
        if (service === s) service = null
        synchronized(lock) {
            if (pendingStarts == 0) {
                live = false
                stopWanted = false
            }
        }
    }

    /** The service called startForeground. True if a pending stop wants it to stop now. */
    internal fun foregrounded(): Boolean {
        lastPost = SystemClock.uptimeMillis()
        return synchronized(lock) {
            if (pendingStarts > 0) pendingStarts--
            if (stopWanted && pendingStarts == 0) {
                stopWanted = false
                live = false
                true
            } else {
                live = !stopWanted
                false
            }
        }
    }

    /**
     * startForeground threw. Returns (noMorePending, shouldNotifyBeam).
     * Never fires nativeFailed if a stop() was already issued or a newer start is pending.
     */
    internal fun startFailed(): Pair<Boolean, Boolean> = synchronized(lock) {
        if (pendingStarts > 0) pendingStarts--
        val wasStopWanted = stopWanted
        if (pendingStarts == 0) stopWanted = false
        live = false
        val noMorePending = pendingStarts == 0
        Pair(noMorePending, noMorePending && !wasStopWanted)
    }

    // The service is stopping itself (undelivered tap, time limit). Returns
    // whether it may stopSelf() now: not while a newer startForegroundService
    // hasn't reached startForeground (Android would crash it); then that
    // start's foregrounded() stops it instead.
    internal fun markStoppedFromService(): Boolean = synchronized(lock) {
        live = false
        if (pendingStarts > 0) stopWanted = true
        pendingStarts == 0
    }

    internal fun snapshot(): NoticeState = synchronized(lock) { state }

    internal fun isSticky(): Boolean = synchronized(lock) { state.sticky }

    internal fun buildForStart(context: Context, mode: Int): Notification {
        val snap = synchronized(lock) {
            if (state.mode == mode) state else state.copy(mode = mode)
        }
        return build(context, snap)
    }

    private fun requestPost() {
        if (service == null || postPending) return
        val wait = lastPost + MIN_POST_MS - SystemClock.uptimeMillis()
        if (wait <= 0) {
            post()
        } else {
            postPending = true
            main.postDelayed({
                postPending = false
                post()
            }, wait)
        }
    }

    private fun post() {
        val s = service ?: return
        val snap = synchronized(lock) {
            if (!live) return
            state
        }
        lastPost = SystemClock.uptimeMillis()
        val nm = s.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build(s, snap))
    }

    private fun build(context: Context, snap: NoticeState): Notification {
        val channelId = if (snap.useActiveChannel) CHANNEL_ACTIVE else CHANNEL_KEEP_ALIVE
        ensureChannel(context, channelId, snap.useActiveChannel)

        val resolvedTitle = if (snap.title.isEmpty() && !snap.useActiveChannel) {
            try {
                context.packageManager.getApplicationLabel(context.applicationInfo).toString()
            } catch (_: Exception) {
                "App"
            }
        } else {
            snap.title
        }

        val icon = if (snap.mode == MODE_MICROPHONE) {
            android.R.drawable.ic_btn_speak_now
        } else {
            android.R.drawable.ic_dialog_info
        }

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(icon)
            .setContentTitle(resolvedTitle)
            .setContentText(snap.text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(
                if (snap.useActiveChannel) NotificationCompat.PRIORITY_DEFAULT
                else NotificationCompat.PRIORITY_LOW
            )
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)

        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            val open = PendingIntent.getActivity(
                context,
                0,
                launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            builder.setContentIntent(open)
        }

        val count = minOf(snap.actionIds.size, snap.actionLabels.size)
        for (i in 0 until count) {
            builder.addAction(0, snap.actionLabels[i], button(context, snap.actionIds[i], i + 1))
        }

        return builder.build()
    }

    private fun ensureChannel(context: Context, channelId: String, activeChannel: Boolean) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(channelId) != null) return
        val channel = if (activeChannel) {
            // Default importance without sound or vibration: LOW files the
            // notification under "Silent" at the bottom of the shade with its
            // action buttons folded away.
            NotificationChannel(channelId, "Background activity", NotificationManager.IMPORTANCE_DEFAULT).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
        } else {
            NotificationChannel(channelId, "Background", NotificationManager.IMPORTANCE_LOW)
        }
        nm.createNotificationChannel(channel)
    }

    private fun button(context: Context, id: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, BeamForegroundService::class.java)
            .setAction(ACTION_BUTTON)
            .putExtra(EXTRA_BUTTON, id)
        return PendingIntent.getService(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }
}
