package dev.audaro.runemobile

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference

/**
 * The "Share logs" report ([Diagnostics] shares it): the app, device and renderer state, the engine's section
 * (version, plugins, thread dump; DiagnosticsBridge), recent app exits, the VM crash report, this app's logcat and
 * the tail of RuneLite's client.log. [Redact] takes tokens, emails and the character's name out of the whole text.
 * iOS RMDiagnostics.m builds the same report; tools/diagnostics/check_report.py checks either.
 */
object DiagnosticsReport {
    // How much of each log goes in. The whole report stays near 1 MB, well under a Discord attachment.
    private const val CLIENT_LOG_TAIL = 512 * 1024L
    private const val LOGCAT_TAIL = 256 * 1024
    private const val CRASH_REPORT_HEAD = 96 * 1024L
    private const val ANR_TRACE_HEAD = 64 * 1024
    private const val ENGINE_WAIT_MS = 3_000L

    /** The report text, redacted. Blocks for up to a few seconds while the engine answers: call it off the main thread. */
    fun text(ctx: Context): String {
        val names = mutableListOf<String>()
        val secrets = mutableListOf<String>()
        tokenFiles(ctx).forEach { f -> runCatching { Redact.collectAccount(f.readText(), names, secrets) } }
        // A sideload bundle may carry tokens.json as an asset (JagexTokens.readSource falls back to it).
        runCatching {
            ctx.assets
                .open("tokens.json")
                .bufferedReader()
                .use { Redact.collectAccount(it.readText(), names, secrets) }
        }

        val home = ctx.filesDir
        val r = StringBuilder()
        r.append("RuneMobile diagnostics report\n")
        r.append(section { headerText(ctx) })
        r.append("\n== Engine ==\n")
        r.append(section { engineText(names) })
        r.append("\n== Recent app exits ==\n")
        r.append(section { exitsText(ctx) })
        r.append("\n== Crash reports ==\n")
        r.append(section { crashReportsIn(home) })
        r.append("\n== App log (logcat) ==\n")
        r.append(section { logcatText() })
        r.append("\n== RuneLite client.log ==\n")
        r.append(section { clientLogIn(File(home, ".runelite/logs")) })
        if (names.isEmpty()) {
            // Logs from an earlier session can still hold the name: say so rather than imply it was removed.
            r.insert(
                r.indexOf("\n") + 1,
                "(No character name was found to take out: logged out, or the account file is unreadable. If your name " +
                    "appears below, remove it before you post this file.)\n",
            )
        }
        return Redact.text(r.toString(), names, secrets)
    }

    // One section's text; a failure in it is reported in place instead of losing the rest of the report.
    private inline fun section(build: () -> String): String =
        runCatching(build).getOrElse { t -> "(couldn't read this part: ${t.javaClass.simpleName}: ${t.message})\n" }

    private fun headerText(ctx: Context): String {
        val am = ctx.getSystemService(ActivityManager::class.java)
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val power = ctx.getSystemService(PowerManager::class.java)
        val battery = ctx.getSystemService(BatteryManager::class.java)
        val thermal =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                listOf("none", "light", "moderate", "severe", "critical", "emergency", "shutdown")
                    .getOrElse(power.currentThermalStatus) { "?" }
            } else {
                "?"
            }
        val dm = ctx.resources.displayMetrics
        val renderer =
            ctx
                .getSharedPreferences("renderer", Context.MODE_PRIVATE)
                .all
                .toSortedMap()
                .entries
                .joinToString(", ") { "${it.key}=${it.value}" }
                .ifEmpty { "defaults" }
        val upMin = (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()) / 60_000
        val made = SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.US).format(Date())
        return buildString {
            append("Made      $made\n")
            append(
                "App       ${BuildConfig.VERSION_NAME} (build ${BuildConfig.VERSION_CODE}, " +
                    "${if (BuildConfig.DEBUG) "debug" else "release"}) on Android | running $upMin min\n",
            )
            append(
                "Device    ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}) | Android ${Build.VERSION.RELEASE} " +
                    "(API ${Build.VERSION.SDK_INT}) | ${Build.SUPPORTED_ABIS.firstOrNull() ?: "?"}\n",
            )
            append(
                "State     %.1f GB RAM, %.1f GB free%s | thermal %s | %s | screen %dx%d @%.2fx\n".format(
                    Locale.US,
                    mem.totalMem / 1073741824.0,
                    mem.availMem / 1073741824.0,
                    if (mem.lowMemory) " (low)" else "",
                    thermal,
                    if (battery.isCharging) "charging" else "on battery",
                    dm.widthPixels,
                    dm.heightPixels,
                    dm.density,
                ),
            )
            append("Renderer  $renderer\n")
        }
    }

    // The engine's section, and the names it reports to take out of the whole report. The call runs on a thread of
    // its own so a frozen engine costs the wait, not the report.
    private fun engineText(names: MutableList<String>): String {
        val box = AtomicReference<String?>(null)
        val t = Thread({ box.set(runCatching { JvmLauncher.nativeEngineDiagnostics() }.getOrNull()) }, "rm-share-logs")
        t.isDaemon = true
        t.start()
        t.join(ENGINE_WAIT_MS)
        // Read the answer only once the thread is known to be done, so a late one can't read as "not running".
        val timedOut = t.isAlive
        val json = if (timedOut) null else box.get()
        val o = json?.let { runCatching { JSONObject(it) }.getOrNull() }
        return when {
            timedOut -> {
                "(the engine didn't answer within ${ENGINE_WAIT_MS / 1000} s: it may be frozen)\n"
            }

            json.isNullOrEmpty() -> {
                "(the game engine isn't running)\n"
            }

            o == null -> {
                "(the engine gave an unreadable report)\n"
            }

            else -> {
                o.optJSONArray("names")?.let { a ->
                    for (i in 0 until a.length()) a.optString(i).takeIf { it.isNotEmpty() }?.let(names::add)
                }
                o.optString("text").ifEmpty { "(the engine gave an empty report)\n" }
            }
        }
    }

    private val EXIT_REASONS =
        listOf(
            "unknown",
            "exited itself",
            "killed by a signal",
            "low memory",
            "Java crash",
            "native crash",
            "not responding (ANR)",
            "failed to start",
            "permission changed",
            "used too many resources",
            "force-stopped",
            "stopped by the user",
            "dependency died",
            "other",
            "frozen",
            "package state changed",
            "updated",
        )

    // Why the app's last few processes ended (Android 11+): the record that survives a crash, a kill or an ANR.
    private fun exitsText(ctx: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "(needs Android 11)\n"
        val am = ctx.getSystemService(ActivityManager::class.java)
        // All of them, newest first by our own sort: the order the list comes back in isn't one to rely on.
        val exits = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 0).sortedByDescending { it.timestamp }.take(6)
        val f = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        val out = StringBuilder()
        if (exits.isEmpty()) out.append("(none recorded)\n")
        var anrTrace: String? = null
        for (e in exits) {
            out.append(
                "${f.format(Date(e.timestamp))}  ${EXIT_REASONS.getOrElse(e.reason) { "reason ${e.reason}" }}" +
                    "  status=${e.status}  importance=${e.importance}  pss=${e.pss / 1024} MB  rss=${e.rss / 1024} MB" +
                    (e.description?.let { "  ($it)" } ?: "") + "\n",
            )
            if (anrTrace == null && e.reason == ApplicationExitInfo.REASON_ANR) {
                anrTrace =
                    runCatching {
                        e.traceInputStream?.use { s ->
                            val bytes = s.readNBytesCompat(ANR_TRACE_HEAD)
                            "-- not-responding trace, ${f.format(Date(e.timestamp))} --\n" + String(bytes, Charsets.UTF_8)
                        }
                    }.getOrNull()
            }
        }
        anrTrace?.let { out.append(it).append(if (it.endsWith("\n")) "" else "\n") }
        return out.toString()
    }

    // The newest VM crash report (-XX:ErrorFile points it at the app's files dir), with its date.
    private fun crashReportsIn(dir: File): String {
        val newest =
            dir
                .listFiles { f -> f.name.startsWith("hs_err_pid") && f.name.endsWith(".log") }
                ?.maxByOrNull { it.lastModified() } ?: return "(none)\n"
        val written = SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.US).format(Date(newest.lastModified()))
        return "-- ${newest.name}, written $written --\n" + headOf(newest, CRASH_REPORT_HEAD)
    }

    // This app's logcat (Android shows an app only its own lines). Release builds keep the VM's own output out of
    // it, so this is the app shell; RuneLite's side is client.log below.
    private fun logcatText(): String {
        val p =
            ProcessBuilder("logcat", "-d", "-v", "threadtime", "-t", "8000")
                .redirectErrorStream(true)
                .start()
        val text = p.inputStream.bufferedReader().use { it.readText() }
        p.waitFor()
        return when {
            text.isBlank() -> {
                "(empty)\n"
            }

            text.length <= LOGCAT_TAIL -> {
                text
            }

            else -> {
                val cut = text.substring(text.length - LOGCAT_TAIL)
                "(last ${LOGCAT_TAIL / 1024} KB)\n" + cut.substring(cut.indexOf('\n') + 1)
            }
        }
    }

    // client.log's tail, plus the newest rolled-over file when today's is short (it rolls at midnight).
    private fun clientLogIn(logs: File): String {
        val current = File(logs, "client.log")
        val out = StringBuilder()
        if (current.length() < CLIENT_LOG_TAIL / 2) {
            logs
                .listFiles { f -> f.name.startsWith("client_") && f.name.endsWith(".log") }
                ?.maxByOrNull { it.lastModified() }
                ?.let { rolled ->
                    out.append("-- ${rolled.name} --\n").append(tailOf(rolled, CLIENT_LOG_TAIL / 2)).append("-- client.log --\n")
                }
        }
        out.append(tailOf(current, CLIENT_LOG_TAIL))
        return out.toString()
    }

    // tokens.json wherever the app reads it from (JagexTokens.locate).
    private fun tokenFiles(ctx: Context): List<File> =
        listOfNotNull(
            File(ctx.filesDir, "tokens.json"),
            if (BuildConfig.DEBUG) ctx.getExternalFilesDir(null)?.let { File(it, "tokens.json") } else null,
        ).filter { it.isFile }
}

// The last `bytes` of a file, starting at a line, or a note saying why there is nothing.
private fun tailOf(
    file: File,
    bytes: Long,
): String =
    when {
        !file.isFile -> {
            "(no file)\n"
        }

        file.length() == 0L -> {
            "(empty)\n"
        }

        else -> {
            RandomAccessFile(file, "r").use { raf ->
                val size = raf.length()
                val from = maxOf(0L, size - bytes)
                val buf = ByteArray((size - from).toInt())
                raf.seek(from)
                raf.readFully(buf)
                // Past the first (partial) line; indexOf's -1 when there is no newline makes this 0.
                val start = if (from > 0) buf.indexOf('\n'.code.toByte()) + 1 else 0
                val s = String(buf, start, buf.size - start, Charsets.UTF_8)
                val cut = if (from > 0) "(last ${bytes shr 10} KB of ${size shr 10} KB)\n" else ""
                cut + s + if (s.endsWith("\n")) "" else "\n"
            }
        }
    }

// The first `bytes` of a file, with a note when there was more.
private fun headOf(
    file: File,
    bytes: Long,
): String =
    RandomAccessFile(file, "r").use { raf ->
        val size = raf.length()
        val buf = ByteArray(minOf(size, bytes).toInt())
        raf.readFully(buf)
        val s = String(buf, Charsets.UTF_8)
        s + (if (s.endsWith("\n")) "" else "\n") +
            (if (size > bytes) "(first ${bytes shr 10} KB of ${size shr 10} KB)\n" else "")
    }

// InputStream.readNBytes(int) needs API 33.
private fun InputStream.readNBytesCompat(max: Int): ByteArray {
    val buf = ByteArray(max)
    var n = 0
    while (n < max) {
        val r = read(buf, n, max - n)
        if (r < 0) break
        n += r
    }
    return buf.copyOf(n)
}
