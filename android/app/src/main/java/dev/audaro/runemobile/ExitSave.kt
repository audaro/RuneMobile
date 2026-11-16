package dev.audaro.runemobile

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Every exit(0) goes through [exitAfterSave]. Android ends the process without the desktop window-close that posts
 * ClientShutdown, which is where plugins save what they keep in memory (Flipping Utilities' trades, the XP Tracker
 * session). The Java half is MobileUiBridge.prepareExit (headless/ExitSave.java); iOS calls it from saveBeforeExit.
 */
object ExitSave {
    /** Longest an exit waits for plugins to save on ClientShutdown. iOS kExitSaveTimeoutMs. */
    const val TIMEOUT_MS = 3_000

    // Java can take up to 1 s past the timeout to let a config write in progress land, plus the bridge queue.
    private const val BACKSTOP_MS = TIMEOUT_MS + 2_000L

    /**
     * Post ClientShutdown on the bridge thread, wait for plugins and save config, then run [exit] on the UI thread.
     * Java bounds its own wait whatever a plugin does, and a UI-thread backstop runs [exit] anyway if the bridge
     * thread is busy or stuck, so an exit never hangs on the save. Before the VM is up the save is a no-op and [exit]
     * follows at once. Call from the UI thread.
     */
    fun exitAfterSave(
        why: String,
        exit: () -> Unit,
    ) {
        val main = Handler(Looper.getMainLooper())
        val once = AtomicBoolean(false)
        val go = Runnable { if (once.compareAndSet(false, true)) exit() }
        main.postDelayed(go, BACKSTOP_MS)
        JvmLauncher.onBridge {
            val ack = runCatching { JvmLauncher.nativePrepareExit(TIMEOUT_MS) }.getOrElse { "failed: ${it.message}" }
            Log.i("ExitSave", "$why: saved before exit -> ${ack.ifEmpty { "(bridge not up)" }}")
            main.post(go)
        }
    }
}
