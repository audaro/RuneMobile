package dev.audaro.runemobile

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.util.Log
import androidx.appcompat.app.AlertDialog
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * "Share logs": one text file a player can post with a bug report, made by [DiagnosticsReport] (app, device and
 * renderer state, the engine's section, recent app exits, the VM crash report, logcat and the tail of RuneLite's
 * client.log, with tokens, emails and the character's name taken out). This object is the button's side: the
 * confirm dialog, the file, and the share sheet. iOS RMDiagnostics.m does the same.
 */
object Diagnostics {
    private const val TAG = "Diagnostics"

    /** The FileProvider authority declared in the manifest. */
    private fun authority(ctx: Context) = "${ctx.packageName}.diagnostics"

    /** Explains what the file holds, then builds it off the main thread and opens the share sheet. */
    fun share(context: Context) {
        val activity = context.findActivity() ?: return
        AlertDialog
            .Builder(activity)
            .setTitle("Share logs")
            .setMessage(
                "This makes a text file to post with your bug report: app and device versions, your plugins, " +
                    "and recent log lines. Login tokens, emails and your character name are taken out first.",
            ).setNegativeButton("Cancel", null)
            .setPositiveButton("Share") { _, _ -> buildAndShare(activity) }
            .show()
    }

    private fun buildAndShare(activity: Activity) {
        val wait =
            AlertDialog
                .Builder(activity)
                .setMessage("Preparing logs…")
                .setCancelable(false)
                .show()
        Thread({
            val file = runCatching { writeReport(activity) }.onFailure { Log.w(TAG, "share logs failed", it) }.getOrNull()
            activity.runOnUiThread {
                if (activity.isFinishing || activity.isDestroyed) return@runOnUiThread
                wait.dismiss()
                if (file == null) {
                    AlertDialog
                        .Builder(activity)
                        .setTitle("Couldn't make the log file")
                        .setMessage("The phone may be out of space.")
                        .setPositiveButton("OK", null)
                        .show()
                    return@runOnUiThread
                }
                val uri = FileProvider.getUriForFile(activity, authority(activity), file)
                val send =
                    Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        putExtra(Intent.EXTRA_SUBJECT, file.name)
                        clipData = ClipData.newRawUri(file.name, uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                activity.startActivity(Intent.createChooser(send, "Share logs"))
            }
        }, "rm-share-logs-build").start()
    }

    // The report in cache/share-logs/ (the FileProvider path), replacing any earlier one so they don't pile up.
    private fun writeReport(ctx: Context): File {
        val text = DiagnosticsReport.text(ctx)
        val dir = File(ctx.cacheDir, "share-logs")
        dir.deleteRecursively()
        check(dir.mkdirs()) { "can't create $dir" }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        return File(dir, "RuneMobile-logs-$stamp.txt").apply { writeText(text) }
    }

    /** Before a boot: keep only the newest [keep] VM crash reports in [dir], so a crash loop can't fill the phone. */
    fun pruneVmCrashReports(
        dir: File,
        keep: Int,
    ) {
        val reports =
            dir
                .listFiles { f -> f.name.startsWith("hs_err_pid") && f.name.endsWith(".log") }
                ?.sortedByDescending { it.lastModified() } ?: return
        reports.drop(keep).forEach { it.delete() }
    }

    private tailrec fun Context.findActivity(): Activity? =
        when (this) {
            is Activity -> this
            is ContextWrapper -> baseContext.findActivity()
            else -> null
        }
}
