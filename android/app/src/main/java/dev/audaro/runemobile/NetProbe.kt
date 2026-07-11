package dev.audaro.runemobile

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL

/**
 * AG2 login diagnosis — determine WHY a home-minted Jagex session fails to log in from a Firebase Test Lab
 * (Google datacenter) device while it works from the home network. Gated by a pushed `netprobe.mode` marker so it
 * only runs in the diagnostic Robo run; logs `NETPROBE …` lines (no secrets — only the session length + HTTP
 * status + a short body snippet). It makes the EXACT call the gamepack makes at login —
 * GET auth.runescape.com/game-session/v2/accounts with `Authorization: Bearer <session_id>` — so the response
 * tells us if the session is accepted from this IP (then the login failure is elsewhere), rejected by auth
 * (IP-binding → mint-on-device might fix), or refused at the network layer (datacenter blocklist → it can't).
 */
object NetProbe {
    private const val TAG = "NETPROBE"

    fun run(ctx: Context) {
        try {
            val ip = httpGet("https://api.ipify.org?format=text", null)
            Log.i(TAG, "device public egress IP: ${ip.body.trim()} (status=${ip.status})")
        } catch (t: Throwable) {
            Log.i(TAG, "public IP lookup failed: ${t.javaClass.simpleName}: ${t.message}")
        }

        // Control: a host unrelated to Jagex, to prove general internet egress works on this device.
        probeHttp("control google", "https://www.google.com/generate_204", null)

        // The session_id (Bearer for the game-session API). Read from the pushed tokens.json.
        val session = readSession(ctx)
        Log.i(TAG, "session_id present=${session != null} length=${session?.length ?: 0}")

        // The EXACT gamepack login call — does Jagex accept this session from THIS device's IP?
        if (session != null) {
            probeHttp(
                "jagex game-session accounts",
                "https://auth.runescape.com/game-session/v2/accounts?fetchMembership=true",
                "Bearer $session",
            )
        }

        // Jagex auth host reachability (the OAuth/mint endpoints), Bearer-less — just the TLS/HTTP layer.
        probeHttp("jagex account.jagex.com", "https://account.jagex.com/", null)

        // The game-world connection is a raw TCP socket on 43594 (NOT http) — test it directly.
        probeTcp("game world oldschool1:43594", "oldschool1.runescape.com", 43594)

        Log.i(TAG, "NETPROBE DONE")
    }

    private data class Resp(
        val status: Int,
        val body: String,
    )

    private fun httpGet(
        url: String,
        auth: String?,
    ): Resp {
        val c =
            (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 10000
                readTimeout = 10000
                requestMethod = "GET"
                setRequestProperty("Accept", "application/json")
                setRequestProperty("User-Agent", "RuneLite")
                if (auth != null) setRequestProperty("Authorization", auth)
            }
        return try {
            val status = c.responseCode
            val stream = if (status in 200..299) c.inputStream else (c.errorStream ?: c.inputStream)
            val body = stream?.bufferedReader()?.use { it.readText() } ?: ""
            Resp(status, body)
        } finally {
            c.disconnect()
        }
    }

    private fun probeHttp(
        label: String,
        url: String,
        auth: String?,
    ) {
        try {
            val r = httpGet(url, auth)
            val snippet = r.body.replace("\n", " ").take(180)
            Log.i(TAG, "$label -> HTTP ${r.status}  body[0..180]=$snippet")
        } catch (t: Throwable) {
            Log.i(TAG, "$label -> NETERR ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun probeTcp(
        label: String,
        host: String,
        port: Int,
    ) {
        val s = Socket()
        try {
            s.connect(InetSocketAddress(host, port), 8000)
            Log.i(TAG, "$label -> TCP CONNECTED (localAddr=${s.localAddress?.hostAddress})")
        } catch (t: Throwable) {
            Log.i(TAG, "$label -> TCP FAIL ${t.javaClass.simpleName}: ${t.message}")
        } finally {
            try {
                s.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun readSession(ctx: Context): String? {
        for (p in listOf(File(ctx.getExternalFilesDir(null), "tokens.json"), File(ctx.filesDir, "tokens.json"))) {
            if (p.exists()) {
                return try {
                    JSONObject(p.readText()).optString("session_id", "").ifEmpty { null }
                } catch (_: Throwable) {
                    null
                }
            }
        }
        return null
    }
}
