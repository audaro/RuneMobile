package dev.audaro.runemobile

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * On-device Jagex OAuth — the Stage-A consent flow, ported verbatim from the proven iOS login
 * (JagexLoginViewController.m) and fetch-shield-tokens.sh. Stage A produces the id_token the game-session API
 * accepts (the launcher client's id_token is rejected INVALID_ID_TOKEN); from it we mint a session + character
 * list and write tokens.json, which [JagexTokens] then maps to the JX_* env the gamepack reads. Initial login +
 * render works off the session_id + chosen account alone (the gamepack mints its own play token), so the
 * optional Stage-B launcher tokens (access/refresh, long-session refresh only) are left empty here.
 *
 * THROWAWAY account only. tokens.json is a gitignored secret; only redacted prefixes are ever logged.
 */
object JagexLogin {
    private const val TAG = "JagexLogin"

    // Verbatim from ios/dev-tools/fetch-shield-tokens.sh / JagexLoginViewController.m.
    // Pinned across all three login impls by tools/shared-contract/auth-contract.json — a change here that
    // isn't mirrored to the iOS port + the script fails check-auth-contract.sh (pre-commit + release gate).
    private const val AUTH_ENDPOINT = "https://account.jagex.com/oauth2/auth"
    private const val CONSENT_CLIENT_ID = "1fddee4e-b100-4f4e-b2b0-097f9088f9d2"
    private const val CONSENT_REDIRECT = "http://localhost"
    private const val CONSENT_SCOPE = "openid offline"
    private const val SESSIONS_URL = "https://auth.runescape.com/game-session/v1/sessions"
    private const val ACCOUNTS_URL = "https://auth.runescape.com/game-session/v2/accounts?fetchMembership=true"

    // Cloudflare in front of the game-session API is User-Agent sensitive — match the official Mac launcher.
    const val LAUNCHER_UA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "JagexLauncher/2.4.4 Chrome/120.0.0.0 Safari/537.36"

    /** A base64url nonce/state token (24 random bytes), matching the iOS randomToken. */
    fun randomToken(): String {
        val buf = ByteArray(24)
        SecureRandom().nextBytes(buf)
        return Base64.encodeToString(buf, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE).trim()
    }

    /** True when the id_token's OIDC `nonce` claim matches the nonce this app minted for the consent URL.
     *  This binds the returned token to THIS sign-in attempt so a planted/replayed link is rejected;
     *  the token itself is then proven against Jagex by the session mint (no local signature check needed). */
    fun nonceMatches(
        idToken: String,
        expectedNonce: String,
    ): Boolean =
        try {
            val parts = idToken.split(".")
            if (parts.size < 2) {
                false
            } else {
                val payload = String(Base64.decode(parts[1], Base64.URL_SAFE), Charsets.UTF_8)
                JSONObject(payload).optString("nonce", "") == expectedNonce
            }
        } catch (e: Exception) {
            false
        }

    /** The Stage-A consent URL (OIDC hybrid: id_token + code; loopback redirect we intercept). */
    fun consentUrl(
        nonce: String,
        state: String,
    ): String {
        fun e(s: String) = URLEncoder.encode(s, "UTF-8")
        return "$AUTH_ENDPOINT?response_type=${e("id_token code")}" +
            "&client_id=$CONSENT_CLIENT_ID" +
            "&redirect_uri=${e(CONSENT_REDIRECT)}" +
            "&scope=${e(CONSENT_SCOPE)}" +
            // Force the login screen. The Android login opens this in a Chrome Custom Tab, which shares the system
            // Chrome cookie jar — without prompt=login a warm Jagex SSO session would silently re-mint the previously
            // logged-in account and defeat account-switching (the iOS WKWebView dodged this with an ephemeral store).
            "&prompt=login" +
            "&nonce=$nonce&state=$state"
    }

    /** Pull a value out of an x-www-form-urlencoded fragment/query (the redirect carries id_token in #frag). */
    fun valueFrom(
        query: String,
        key: String,
    ): String? {
        for (pair in query.split("&")) {
            val eq = pair.indexOf('=')
            if (eq < 0) continue
            if (pair.substring(0, eq) == key) {
                val v = pair.substring(eq + 1)
                return try {
                    java.net.URLDecoder.decode(v, "UTF-8")
                } catch (e: Exception) {
                    v
                }
            }
        }
        return null
    }

    /** POST the id_token to game-session → sessionId (null on failure). Blocking — call off the UI thread. */
    fun mintSession(idToken: String): String? {
        val body = JSONObject().put("idToken", idToken).toString()
        val (code, text) = post(SESSIONS_URL, body, bearer = null)
        if (code != 200) {
            Log.w(TAG, "session mint HTTP $code: ${snippet(text)}")
            return null
        }
        val sid =
            try {
                JSONObject(text).optString("sessionId", "")
            } catch (e: Exception) {
                ""
            }
        return sid.ifEmpty {
            Log.w(TAG, "session response had no sessionId: ${snippet(text)}")
            null
        }
    }

    /** GET the character list with Bearer sessionId (null/empty on failure). Blocking — off the UI thread. */
    fun fetchAccounts(sessionId: String): JSONArray? {
        val (code, text) = get(ACCOUNTS_URL, bearer = sessionId)
        if (code != 200) {
            Log.w(TAG, "accounts HTTP $code: ${snippet(text)}")
            return null
        }
        return try {
            JSONArray(text)
        } catch (e: Exception) {
            Log.w(TAG, "accounts not an array: ${snippet(text)}")
            null
        }
    }

    /** A display label for an account (displayName, else a redacted accountId tail). */
    fun accountLabel(a: JSONObject): String {
        val name = a.optString("displayName", "")
        if (name.isNotEmpty()) return name
        val id = a.optString("accountId", "")
        return "Unnamed character (…${if (id.length > 4) id.takeLast(4) else id})"
    }

    /**
     * Write tokens.json to the app's internal filesDir (where the JRE lives and [JagexTokens.locate] looks
     * first). Stage-A fields only (session_id + chosen account + the full account list); access/refresh left
     * empty. mode is internal-only (filesDir is private to the app). Returns true on success.
     */
    fun writeTokens(
        ctx: Context,
        sessionId: String,
        chosen: JSONObject,
        accounts: JSONArray,
    ): Boolean =
        try {
            val iso =
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
                    .apply {
                        timeZone = TimeZone.getTimeZone("UTC")
                    }.format(Date())
            val json =
                JSONObject()
                    .put("access_token", "")
                    .put("refresh_token", "")
                    .put("id_token", "")
                    .put("expires_in", 0)
                    .put("scope", "")
                    .put("session_id", sessionId)
                    .put("accounts", accounts)
                    .put("otl_token", "")
                    .put("fetched_at", iso)
                    .put("chosen_account_id", chosen.optString("accountId", ""))
                    .put("chosen_display_name", chosen.optString("displayName", ""))
                    .put(
                        "notes",
                        "On-device Jagex login (A3, Stage-A consent). JagexTokens maps session_id->JX_SESSION_ID, " +
                            "chosen_account_id->JX_CHARACTER_ID, chosen_display_name->JX_DISPLAY_NAME; the gamepack mints its " +
                            "own play token. access/refresh empty (Stage-A only).",
                    )
            File(ctx.filesDir, "tokens.json").writeText(json.toString())
            JagexTokens.clearLoggedOut(ctx) // a fresh login owns the session — drop the logout suppression
            val sp = if (sessionId.length >= 6) sessionId.substring(0, 6) else sessionId
            Log.i(
                TAG,
                "tokens.json written (filesDir): displayName='${chosen.optString("displayName", "")}' " +
                    "characterId=${chosen.optString("accountId", "")} session=$sp…",
            )
            true
        } catch (e: Exception) {
            Log.e(TAG, "tokens.json write failed: ${e.message}")
            false
        }

    // ---- HTTP (HttpURLConnection; launcher UA for Cloudflare) -------------------------------------------

    private fun post(
        urlStr: String,
        body: String,
        bearer: String?,
    ): Pair<Int, String> = request(urlStr, "POST", body, bearer)

    private fun get(
        urlStr: String,
        bearer: String?,
    ): Pair<Int, String> = request(urlStr, "GET", null, bearer)

    private fun request(
        urlStr: String,
        method: String,
        body: String?,
        bearer: String?,
    ): Pair<Int, String> {
        var conn: HttpURLConnection? = null
        return try {
            conn =
                (URL(urlStr).openConnection() as HttpURLConnection).apply {
                    requestMethod = method
                    connectTimeout = 15000
                    readTimeout = 20000
                    setRequestProperty("User-Agent", LAUNCHER_UA)
                    setRequestProperty("Accept", "application/json")
                    bearer?.let { setRequestProperty("Authorization", "Bearer $it") }
                    if (body != null) {
                        doOutput = true
                        setRequestProperty("Content-Type", "application/json")
                        outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    }
                }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            code to text
        } catch (e: Exception) {
            Log.w(TAG, "$method $urlStr failed: ${e.message}")
            -1 to (e.message ?: "")
        } finally {
            conn?.disconnect()
        }
    }

    private fun snippet(s: String): String = if (s.length > 200) s.substring(0, 200) + "…" else s
}
