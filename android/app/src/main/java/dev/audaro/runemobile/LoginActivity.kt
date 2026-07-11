package dev.audaro.runemobile

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import org.json.JSONArray
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * A3 on-device Jagex login — no computer required.
 *
 * Android's WebView is bot-blocked by Cloudflare at the Jagex *auth* step (the human check wants an Apple
 * device-attestation Private Access Token the embedded WebView can't produce — see ANDROID-LOGIN-DEEPDIVE.md;
 * the partition test proved real Chrome passes where the WebView is blocked). And the consent OAuth client
 * accepts ONLY redirect_uri=http://localhost (loopback-port and custom-scheme redirects are rejected — proven
 * on-device), so the redirect can't be auto-routed back into the app. This flow therefore hands the auth to
 * real Chrome and brings the result back by hand:
 *   1. open the Stage-A consent URL in a Chrome Custom Tab (real Chrome clears Cloudflare + the human check),
 *   2. the user signs in; Chrome lands on http://localhost/#id_token=… ("localhost refused to connect"),
 *   3. the user copies that link; on return we read it from the clipboard (or they paste it below),
 *   4. the id_token is minted into a game session + character list ([JagexLogin]), a character is picked, and
 *      tokens.json is written; the process restarts so JNI_CreateJavaVM re-snapshots JX_* (login-first rule).
 *
 * The mint/REST calls use the launcher UA and are NOT bot-blocked. Only redacted lines are logged — never a token.
 */
class LoginActivity : AppCompatActivity() {
    private lateinit var status: TextView
    private lateinit var pasteField: EditText
    private var nonce = JagexLogin.randomToken()
    private var state = JagexLogin.randomToken()
    private var launched = false // user has opened the consent flow at least once this session
    private var importing = false // a mint is in flight — don't re-enter
    private var done = false // captured a valid id_token — handle exactly once
    private var lastTried: String? = null

    // UX-LOGIN-1: the layout paddings/margins were raw px, so the screen shrank on high-density phones.
    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launched = savedInstanceState?.getBoolean("launched") ?: false
        // The consent URL was minted with THIS instance's nonce/state — restore them across an Activity
        // recreation (rotation/theme flip mid-browser-trip) or the returning link would fail the binding check.
        savedInstanceState?.getString("nonce")?.let { nonce = it }
        savedInstanceState?.getString("state")?.let { state = it }

        val root =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(Color.BLACK)
            }

        val bar =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setBackgroundColor(Color.rgb(26, 26, 26))
                setPadding(dp(12), dp(6), dp(12), dp(6))
            }
        bar.addView(
            TextView(this).apply {
                text = "Log in with Jagex"
                setTextColor(Color.WHITE)
                textSize = 16f
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            },
        )
        bar.addView(
            Button(this).apply {
                text = "Close"
                setOnClickListener { cancelAndExit() }
            },
        )
        root.addView(bar, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val content =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16), dp(12), dp(16), dp(12))
            }

        content.addView(
            TextView(this).apply {
                setTextColor(Color.WHITE)
                textSize = 14f
                text = "Sign in to your Jagex account in your browser, then bring the link back here.\n\n" +
                    "1.  Tap “Open Jagex login” and sign in.\n" +
                    "2.  You'll land on a page that says “localhost refused to connect” — that's expected.\n" +
                    "3.  Copy that page's link: tap the Share icon, then “Copy”.\n" +
                    "4.  Tap back to return here — it imports automatically.\n" +
                    "     (Or paste the link below and tap Import.)"
            },
        )

        content.addView(
            Button(this).apply {
                text = "Open Jagex login"
                textSize = 16f
                setOnClickListener { launchConsent() }
            },
            LinearLayout
                .LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(14) },
        )

        pasteField =
            EditText(this).apply {
                setTextColor(Color.WHITE)
                setHintTextColor(Color.GRAY)
                hint = "Paste the http://localhost/… link here"
                textSize = 13f
                setSingleLine(true)
            }
        content.addView(
            pasteField,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin =
                    dp(12)
            },
        )

        content.addView(
            Button(this).apply {
                text = "Import login link"
                setOnClickListener {
                    val t =
                        pasteField.text
                            ?.toString()
                            ?.trim()
                            .orEmpty()
                    if (!tryImport(t)) log("✗ no Jagex login link found — copy the “localhost” link from your browser first")
                }
            },
            LinearLayout
                .LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(5) },
        )

        root.addView(
            ScrollView(this).apply { addView(content) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        status =
            TextView(this).apply {
                setTextColor(Color.GREEN)
                setBackgroundColor(Color.rgb(13, 13, 13))
                textSize = 12f
                setPadding(dp(12), dp(6), dp(12), dp(6))
                text = "Ready."
            }
        root.addView(status, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        setContentView(root)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("launched", launched)
        outState.putString("nonce", nonce)
        outState.putString("state", state)
    }

    /** Open the Stage-A consent flow in a Chrome Custom Tab (real Chrome clears Cloudflare + the human check). */
    private fun launchConsent() {
        launched = true
        lastTried = null
        log("Opening Jagex login in your browser…")
        val url = Uri.parse(JagexLogin.consentUrl(nonce, state))
        try {
            CustomTabsIntent
                .Builder()
                .setShareState(CustomTabsIntent.SHARE_STATE_ON) // gives a Share ▸ Copy on the localhost page
                .build()
                .launchUrl(this, url)
        } catch (e: Exception) {
            // No Custom Tabs provider — fall back to whatever handles a web link.
            try {
                startActivity(Intent(Intent.ACTION_VIEW, url))
            } catch (e2: Exception) {
                log("✗ no browser available to open the login")
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Reading the clipboard needs window focus; this fires once we're genuinely foreground after the browser.
        // (Driven only from here, not onResume too, to avoid a duplicate clipboard read + its system "pasted" toast.)
        if (hasFocus) maybeAutoImport()
    }

    /** The smooth path: the moment we're back in focus after the browser, auto-read the redirect link the user
     *  copied and start the import. Gated on a prior launch + a localhost/id_token shape so we never act on
     *  unrelated clipboard content. */
    private fun maybeAutoImport() {
        if (!launched || importing || done) return
        val t = clipboardText() ?: return
        if (t != lastTried && t.contains("id_token=") && t.contains("localhost")) tryImport(t)
    }

    private fun clipboardText(): String? =
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(this)
                ?.toString()
                ?.trim()
        } catch (e: Exception) {
            null
        }

    /** Pull the id_token from a copied/pasted http://localhost/#… link and start the mint. Returns true if a
     *  token was found (or one is already being handled), false if the text carried no usable token. */
    private fun tryImport(text: String): Boolean {
        if (importing || done) return true
        if (text.isEmpty()) return false
        lastTried = text
        val fragment = if (text.contains('#')) text.substringAfter('#') else text
        val idToken = JagexLogin.valueFrom(fragment, "id_token")
        if (idToken.isNullOrEmpty()) return false
        // OAuth return-leg binding: the redirect fragment must carry OUR `state`, and the id_token's OIDC
        // `nonce` claim must be the one we minted for the consent URL. The return channel here is the
        // world-readable clipboard, so without this a co-installed app could plant a foreign
        // http://localhost/#id_token=… during the login window (login CSRF into an attacker's account).
        val returnedState = JagexLogin.valueFrom(fragment, "state")
        if (returnedState != state || !JagexLogin.nonceMatches(idToken, nonce)) {
            log("✗ that login link is stale or from another sign-in attempt — tap “Sign in with Jagex” and copy the fresh link")
            return false
        }
        done = true
        clearLink()
        handleRedirect(idToken)
        return true
    }

    /** Best-effort: wipe the captured link from the paste field and the system clipboard once we hold the token, so
     *  the id_token isn't left sitting in clipboard history / a clipboard manager. */
    private fun clearLink() {
        try {
            pasteField.text?.clear()
        } catch (e: Exception) {
            // ignore
        }
        try {
            (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).clearPrimaryClip()
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun handleRedirect(idToken: String) {
        importing = true
        log("✓ link captured — minting game session…")
        thread(name = "jagex-login") {
            val sessionId = JagexLogin.mintSession(idToken)
            if (sessionId == null) {
                runOnUiThread {
                    importing = false
                    done = false
                    log("✗ session mint failed — the link may be expired; reopen the login and copy a fresh one")
                }
                return@thread
            }
            val accounts = JagexLogin.fetchAccounts(sessionId)
            if (accounts == null || accounts.length() == 0) {
                runOnUiThread {
                    importing = false
                    done = false
                    log("✗ no characters returned (see logcat)")
                }
                return@thread
            }
            runOnUiThread {
                log("✓ ${accounts.length()} character(s) — choose one")
                presentPicker(sessionId, accounts)
            }
        }
    }

    private fun presentPicker(
        sessionId: String,
        accounts: JSONArray,
    ) {
        // The mint network window is up to ~35s and "Close" stays live the whole time; if the user closed the
        // screen, don't add a dialog window to a finished Activity (BadTokenException).
        if (isFinishing || isDestroyed) return
        if (accounts.length() == 1) {
            finishWith(sessionId, accounts.getJSONObject(0), accounts)
            return
        }
        val labels = (0 until accounts.length()).map { JagexLogin.accountLabel(accounts.getJSONObject(it)) }.toTypedArray()
        AlertDialog
            .Builder(this)
            .setTitle("Choose character")
            .setItems(labels) { _, which -> finishWith(sessionId, accounts.getJSONObject(which), accounts) }
            // Dismiss re-arms the screen (don't kill the app); the user can reopen the login and try again.
            .setNegativeButton("Cancel") { _, _ ->
                importing = false
                done = false
                log("Cancelled — tap “Open Jagex login” to try again")
            }.setCancelable(false)
            .show()
    }

    private fun finishWith(
        sessionId: String,
        chosen: JSONObject,
        accounts: JSONArray,
    ) {
        val name = chosen.optString("displayName", "")
        log("✓ selected ${name.ifEmpty { "(unnamed)" }} — writing tokens + restarting", sensitive = true)
        if (!JagexLogin.writeTokens(this, sessionId, chosen, accounts)) {
            log("✗ tokens.json write failed")
            return
        }
        restartIntoCleanBoot()
    }

    /** Relaunch the app in a fresh task + kill this process, so JNI_CreateJavaVM re-snapshots JX_* from the
     *  newly-written tokens.json (Review-2: login-first or a clean process restart). */
    private fun restartIntoCleanBoot() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            startActivity(intent)
        }
        finishAffinity()
        Runtime.getRuntime().exit(0) // even if the relaunch intent was null, a manual relaunch re-snapshots JX_*
    }

    private fun cancelAndExit() {
        setResult(RESULT_CANCELED)
        finish()
    }

    /** @param sensitive when true, the line carries account PII (e.g. the character display name) and is
     *  kept out of release logcat — it still shows in the on-screen status, which is the user's own screen.
     *  Mirrors the iOS shell, which DEBUG-gates the identical "selected <name>" line. */
    private fun log(
        line: String,
        sensitive: Boolean = false,
    ) {
        if (!sensitive || BuildConfig.DEBUG) Log.i("JagexLogin", "[login] $line")
        runOnUiThread { status.text = line }
    }
}
