package dev.audaro.runemobile

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Maps a tokens.json -> the JX_* environment the OSRS gamepack reads when "launched from the Jagex
 * launcher", mirroring the proven iOS loadJagexTokens (JVMLauncher.m). tokens.json is a gitignored secret
 * (throwaway account), normally pushed into the app's files dir at test time. A build-time bundled copy is
 * the lowest-priority fallback (a pushed file wins, so refreshed tokens never need a rebuild). PROD-SECURITY-01:
 * that bundled copy lives under `src/debug/assets/tokens.json`, so it ships ONLY in DEBUG builds (personal
 * sideload bundles, e.g. Quest/SideQuest installs where adb-pushing files is impractical) — a RELEASE artifact
 * never carries the secret, and its first launch falls through to the login gate (no asset -> autologin DISABLED).
 *
 * The JX_* env MUST be set before JNI_CreateJavaVM (HotSpot snapshots the environment at startup), so
 * [loadAndArm] runs on the boot thread before [JvmLauncher.startJvm] and sets each var via the native setenv
 * bridge. Returns true iff a usable session (session_id + chosen_account_id) was found, so autologin only arms
 * when we can authenticate. Logs redacted prefixes only — never the secret token values.
 *
 * Push at test time (debug build), e.g.:
 *   adb push tokens.json /sdcard/Android/data/dev.audaro.runemobile/files/tokens.json
 */
object JagexTokens {
    private const val TAG = "JagexTokens"

    /** Locate tokens.json: internal filesDir always; the adb-pushable external dir ONLY in DEBUG builds (A8 — a
     *  release build keeps the secret internal-only, while dev keeps the `adb push …/files/tokens.json` flow). */
    private fun locate(ctx: Context): File? {
        val candidates =
            listOfNotNull(
                File(ctx.filesDir, "tokens.json"),
                if (BuildConfig.DEBUG) ctx.getExternalFilesDir(null)?.let { File(it, "tokens.json") } else null,
            )
        return candidates.firstOrNull { it.exists() && it.length() > 0 }
    }

    /** Logged-out marker: a bundled-asset tokens.json (sideload bundles) can't be deleted, so logout writes
     *  this to suppress the ASSET fallback until the next successful login clears it. A pushed/written
     *  tokens.json still wins regardless — a fresh login or adb push immediately re-arms. */
    private fun loggedOutMarker(ctx: Context): File = File(ctx.filesDir, "logged_out.marker")

    /** Token JSON text + a loggable origin: a pushed file wins (see [locate]); else the bundled asset
     *  (unless suppressed by the logout marker). */
    private fun readSource(ctx: Context): Pair<String, String>? {
        locate(ctx)?.let { return it.readText() to it.parent.orEmpty() }
        if (loggedOutMarker(ctx).exists()) {
            return null // logged out: don't resurrect the session from the bundled asset
        }
        return try {
            ctx.assets
                .open("tokens.json")
                .bufferedReader()
                .use { it.readText() } to "bundled asset"
        } catch (e: Exception) {
            null
        }
    }

    /** A fresh login owns the session again — drop the logout suppression. */
    fun clearLoggedOut(ctx: Context) {
        loggedOutMarker(ctx).delete()
    }

    /** True iff a usable tokens.json (session_id + chosen_account_id) exists — the A3 login-first boot gate. */
    fun hasTokens(ctx: Context): Boolean {
        val (text, _) = readSource(ctx) ?: return false
        return try {
            val t = JSONObject(text)
            t.optString("session_id", "").isNotEmpty() && t.optString("chosen_account_id", "").isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }

    /** Log out: delete every deletable tokens.json copy (internal filesDir + the adb-pushable external dir —
     *  both unconditionally; a stale pushed copy must not resurrect the session on a release build's next
     *  boot) and write the logout marker so a build-time bundled asset (sideload bundles, undeletable) can't
     *  re-arm the session either. Returns true iff no usable session remains. */
    fun deleteAll(ctx: Context): Boolean {
        for (f in listOfNotNull(
            File(ctx.filesDir, "tokens.json"),
            ctx.getExternalFilesDir(null)?.let { File(it, "tokens.json") },
            // a legacy username/password file is a session too — logout must forget it as well
            File(ctx.filesDir, "legacy_login.json"),
            ctx.getExternalFilesDir(null)?.let { File(it, "legacy_login.json") },
        )) {
            if (f.exists() && !f.delete()) Log.w(TAG, "logout: failed to delete ${f.absolutePath}")
        }
        try {
            loggedOutMarker(ctx).writeText("1")
        } catch (e: Exception) {
            Log.w(TAG, "logout: marker write failed: ${e.message}")
        }
        return !hasTokens(ctx)
    }

    /** Parse tokens.json and set JX_* env. Returns true iff autologin was armed. */
    fun loadAndArm(ctx: Context): Boolean {
        val source = readSource(ctx)
        if (source == null) {
            Log.i(TAG, "no tokens.json (filesDir, external files dir, or bundled asset) — autologin DISABLED (login-screen render only)")
            return false
        }
        val (text, origin) = source
        val t =
            try {
                JSONObject(text)
            } catch (e: Exception) {
                Log.w(TAG, "tokens.json parse failed: ${e.message} — autologin DISABLED")
                return false
            }
        val session = t.optString("session_id", "")
        val character = t.optString("chosen_account_id", "")
        val display = t.optString("chosen_display_name", "")
        val access = t.optString("access_token", "")
        val refresh = t.optString("refresh_token", "")
        if (session.isEmpty() || character.isEmpty()) {
            Log.i(TAG, "tokens.json missing session_id/chosen_account_id — autologin DISABLED")
            return false
        }

        JvmLauncher.setEnv("JX_SESSION_ID", session)
        JvmLauncher.setEnv("JX_CHARACTER_ID", character)
        if (display.isNotEmpty()) JvmLauncher.setEnv("JX_DISPLAY_NAME", display)
        if (access.isNotEmpty()) JvmLauncher.setEnv("JX_ACCESS_TOKEN", access)
        if (refresh.isNotEmpty()) JvmLauncher.setEnv("JX_REFRESH_TOKEN", refresh)

        // A8: log account PII (display name / character id / session prefix) ONLY in DEBUG builds; a release
        // build logs a minimal armed line with no identifying data.
        if (BuildConfig.DEBUG) {
            val sessionPrefix = if (session.length >= 6) session.substring(0, 6) else session
            Log.i(
                TAG,
                "JX_* set from $origin: displayName='$display' characterId=$character session=$sessionPrefix… " +
                    "access=${if (access.isNotEmpty()) "set" else "empty"} refresh=${if (refresh.isNotEmpty()) "set" else "empty"}",
            )
        } else {
            Log.i(TAG, "JX_* set — autologin ARMED")
        }
        return true
    }

    /**
     * The autologin VM opts armed once JX_* is set, mirroring iOS JVMLauncher.m. Coordinates are the fixed
     * 765x503 login layout (EULA Accept centre; Play Now centre, desktop-proven); device-tunable via the same
     * runelite.headless.autologin.* properties if a real device's login frame differs.
     */
    val autologinOpts: Array<String> =
        arrayOf(
            "-Drunelite.headless.autologin=true",
            "-Drunelite.headless.autologin.eula=true",
            "-Drunelite.headless.autologin.eula.point=302,312",
            "-Drunelite.headless.autologin.eula.loginIndex=12",
            "-Drunelite.headless.autologin.point=382,248",
            "-Drunelite.headless.autologin.world=301",
            "-Drunelite.headless.autologin.worldAddress=oldschool1.runescape.com",
        )
}
