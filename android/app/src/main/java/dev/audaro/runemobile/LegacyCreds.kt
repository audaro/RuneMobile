package dev.audaro.runemobile

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Legacy (non-Jagex) account autologin: a legacy_login.json ({"username":..,"password":..}) maps to the
 * RL_LEGACY_USER / RL_LEGACY_PASS environment HeadlessLogin's legacy stage reads, mirroring how
 * [JagexTokens] maps tokens.json to JX_*. Like JX_*, the env MUST be set before JNI_CreateJavaVM
 * (HotSpot snapshots the environment at startup), so [loadAndArm] runs on the boot thread before
 * [JvmLauncher.startJvm]. A tokens.json session wins when both exist (the caller arms legacy only when
 * JX autologin didn't arm). The file is a gitignored secret pushed at test time:
 *
 *   adb push legacy_login.json /sdcard/Android/data/dev.audaro.runemobile/files/legacy_login.json
 *
 * (written by android/dev-tools/a3-login/set-legacy-login.sh). Never log the password.
 */
object LegacyCreds {
    private const val TAG = "LegacyCreds"

    /** Locate legacy_login.json. PROD-SECURITY-03: legacy username/password autologin is a DEV-ONLY convenience
     *  whose credential is stored in plaintext — so it is DROPPED from release entirely (a release build never
     *  reads or arms it; Jagex OAuth is the only release login path). DEBUG reads internal filesDir + the
     *  adb-pushable external dir; logout still purges the file in every build (JagexTokens.deleteAll). */
    private fun locate(ctx: Context): File? {
        if (!BuildConfig.DEBUG) return null
        val candidates =
            listOfNotNull(
                File(ctx.filesDir, "legacy_login.json"),
                ctx.getExternalFilesDir(null)?.let { File(it, "legacy_login.json") },
            )
        return candidates.firstOrNull { it.exists() && it.length() > 0 }
    }

    private fun parse(ctx: Context): Pair<String, String>? {
        val f = locate(ctx) ?: return null
        return try {
            val o = JSONObject(f.readText())
            val u = o.optString("username", "")
            val p = o.optString("password", "")
            if (u.isEmpty() || p.isEmpty()) null else u to p
        } catch (e: Exception) {
            Log.w(TAG, "legacy_login.json parse failed: ${e.message}")
            null
        }
    }

    /** True iff a usable legacy_login.json exists — lets the A3 login-first boot gate proceed without a
     *  Jagex session. */
    fun hasCreds(ctx: Context): Boolean = parse(ctx) != null

    /** Set RL_LEGACY_USER / RL_LEGACY_PASS for HeadlessLogin's legacy stage. Returns true iff armed. */
    fun loadAndArm(ctx: Context): Boolean {
        val (user, pass) = parse(ctx) ?: return false
        JvmLauncher.setEnv("RL_LEGACY_USER", user)
        JvmLauncher.setEnv("RL_LEGACY_PASS", pass)
        if (BuildConfig.DEBUG) {
            Log.i(TAG, "RL_LEGACY_* set: user='${user.take(2)}…' (legacy username/password autologin ARMED)")
        } else {
            Log.i(TAG, "RL_LEGACY_* set — legacy autologin ARMED")
        }
        return true
    }
}
