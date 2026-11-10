// Detekt's shape rules are relaxed for this file only: the parser checks one field per line and returns its own
// reason for each refusal, rule for rule with the iOS twin (RMGameUpdate.m), which is what keeps the two in step.
@file:Suppress("ReturnCount", "CyclomaticComplexMethod", "LongParameterList", "ComplexCondition")

package dev.audaro.runemobile

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.time.Instant
import java.util.Base64

/**
 * The pure half of game updates (see [GameUpdate]): signature, manifest parsing and file checks, with no Android
 * calls, so the unit tests run it on the desktop JVM. tools/game-update/make-manifest.py writes what this reads, and
 * ios/app/RuneMobile/RMGameUpdate.m applies the same rules; keep the three in step.
 */
object GameUpdateRules {
    const val KIND = "rune-mobile-game-update"
    const val MANIFEST_MAX = 256 * 1024
    const val SIG_MAX = 512
    const val FILE_MAX = 64L shl 20

    private val ID = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    private val RUNELITE = Regex("[0-9A-Za-z.+-]{1,40}")
    private val HUB = Regex("[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}")
    private val SHA256 = Regex("[0-9a-f]{64}")
    private val COMMIT = Regex("[0-9a-f]{40}")

    /** The jars an Android set holds, by role. The client jars carry the RuneLite version in their names. */
    val ANDROID_ROLES: Map<String, Regex> =
        linkedMapOf(
            "gpu" to Regex("client-[0-9A-Za-z.+_-]{1,60}-gpu\\.jar"),
            "rlhd" to Regex("client-[0-9A-Za-z.+_-]{1,60}-rlhd\\.jar"),
            "probes" to Regex("probes\\.jar"),
        )

    class FileEntry(
        val name: String,
        val url: String,
        val size: Long,
        val sha256: String,
    )

    /** One set of jars for this build, from a manifest whose signature passed. */
    class GameSet(
        val id: String,
        val manifestRevision: Int,
        val gameRevision: Int,
        val runelite: String,
        val pluginHubVersion: String?,
        val required: Boolean,
        /** role -> file */
        val files: Map<String, FileEntry>,
    ) {
        val totalBytes: Long get() = files.values.sumOf { it.size }

        /** The installed directory, once the set is on disk and verified. */
        var dir: File? = null

        /** The exact manifest bytes and signature the set came from, written beside the jars on install. */
        var manifestBytes: ByteArray? = null
        var signature: ByteArray? = null

        fun jar(role: String): File = File(dir, files.getValue(role).name)
    }

    /** [set] for this build, or null with [why]. [revision] is the manifest's whenever its top level is valid. */
    class Parsed(
        val set: GameSet?,
        val revision: Int,
        val why: String?,
    )

    fun isCommit(s: String): Boolean = COMMIT.matches(s)

    /** Whether [signature] (DER ECDSA P-256 over SHA-256) signs [message] under any of [pins] (SPKI DER, base64). */
    fun verifySignature(
        message: ByteArray,
        signature: ByteArray,
        pins: List<String>,
    ): Boolean {
        if (message.isEmpty() || signature.isEmpty() || signature.size > SIG_MAX) return false
        for (pin in pins) {
            val ok =
                runCatching {
                    val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(pin)))
                    Signature.getInstance("SHA256withECDSA").run {
                        initVerify(key)
                        update(message)
                        verify(signature)
                    }
                }.getOrDefault(false)
            if (ok) return true
        }
        return false
    }

    private fun integer(v: Any?): Long? =
        when (v) {
            is Int -> v.toLong()
            is Long -> v
            else -> null
        }

    private fun string(v: Any?): String? = v as? String

    private fun urlAllowed(
        url: String?,
        allowLoopbackHttp: Boolean,
    ): Boolean {
        if (url == null || url.length > 2048) return false
        val u = runCatching { java.net.URI(url) }.getOrNull() ?: return false
        if (u.host.isNullOrEmpty()) return false
        if (u.scheme == "https") return true
        // The local test server is plain HTTP on loopback; debug builds only.
        return allowLoopbackHttp && u.scheme == "http" && (u.host == "127.0.0.1" || u.host == "localhost")
    }

    /** Parse a manifest whose signature already passed and pick the set for [port] + [shell]. */
    fun parse(
        data: ByteArray,
        port: String,
        shell: String,
        roles: Map<String, Regex>,
        bad: Set<String>,
        checkExpiry: Boolean,
        nowMs: Long,
        allowLoopbackHttp: Boolean,
    ): Parsed {
        fun no(
            why: String,
            rev: Int = 0,
        ) = Parsed(null, rev, why)
        val root = runCatching { JSONObject(String(data, Charsets.UTF_8)) }.getOrNull() ?: return no("manifest is not a JSON object")
        if (integer(root.opt("schema")) != 1L) return no("unknown manifest schema")
        if (root.opt("kind") != KIND) return no("manifest kind is wrong")
        val rev =
            integer(root.opt("revision"))?.takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt() ?: return no("manifest revision is invalid")
        val expires =
            string(root.opt("expires"))?.let { runCatching { Instant.parse(it) }.getOrNull() } ?: return no("manifest expiry is invalid")
        val sets = root.opt("sets") as? JSONArray
        if (sets == null || sets.length() > 64) return no("manifest sets are invalid")
        if (checkExpiry && expires.toEpochMilli() < nowMs) return no("manifest has expired", rev)
        var mine: JSONObject? = null
        for (i in 0 until sets.length()) {
            val s = sets.opt(i) as? JSONObject ?: return no("a manifest set is not an object", rev)
            if (s.opt("port") != port || s.opt("shell") != shell) continue
            if (mine != null) return no("manifest has two sets for this build", rev)
            mine = s
        }
        if (mine == null) return no("manifest has no set for this build", rev)
        val id = string(mine.opt("id"))?.takeIf { ID.matches(it) } ?: return no("set id is invalid", rev)
        val game = integer(mine.opt("gameRevision"))?.takeIf { it in 1..100000 }?.toInt() ?: return no("set game revision is invalid", rev)
        val runelite = string(mine.opt("runelite"))?.takeIf { RUNELITE.matches(it) } ?: return no("set runelite version is invalid", rev)
        val hubRaw = mine.opt("pluginHubVersion")
        val hub =
            if (hubRaw == null || hubRaw == JSONObject.NULL) {
                null
            } else {
                string(hubRaw)?.takeIf { HUB.matches(it) } ?: return no("set plugin hub version is invalid", rev)
            }
        val reqRaw = mine.opt("required")
        if (reqRaw != null && reqRaw !is Boolean) return no("set required flag is invalid", rev)
        val files = mine.opt("files") as? JSONArray ?: return no("set files are invalid", rev)
        val byRole = LinkedHashMap<String, FileEntry>()
        for (i in 0 until files.length()) {
            val f = files.opt(i) as? JSONObject ?: return no("a set file entry is invalid", rev)
            val name = string(f.opt("name"))
            val role = roles.entries.firstOrNull { name != null && it.value.matches(name) }?.key
            val url = string(f.opt("url"))
            val size = integer(f.opt("size"))
            val sha = string(f.opt("sha256"))
            if (name == null || role == null || byRole.containsKey(role) || !urlAllowed(url, allowLoopbackHttp) ||
                size == null || size < 1 || size > FILE_MAX || sha == null || !SHA256.matches(sha)
            ) {
                return no("a set file entry is invalid", rev)
            }
            byRole[role] = FileEntry(name, url!!, size, sha)
        }
        if (byRole.size != roles.size) return no("set does not name every jar", rev)
        if (id in bad) return no("set $id is marked bad on this phone", rev)
        return Parsed(GameSet(id, rev, game, runelite, hub, reqRaw == true, byRole), rev, null)
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Null when [file] has [want]'s size and SHA-256, else why not. */
    fun fileMismatch(
        file: File,
        want: FileEntry,
    ): String? {
        if (!file.isFile) return "${want.name} is missing"
        val md = MessageDigest.getInstance("SHA-256")
        var n = 0L
        val ok =
            runCatching {
                file.inputStream().use { input ->
                    val buf = ByteArray(1 shl 20)
                    while (true) {
                        val r = input.read(buf)
                        if (r < 0) break
                        md.update(buf, 0, r)
                        n += r
                    }
                }
            }.isSuccess
        if (!ok) return "${want.name} is unreadable"
        val hex = md.digest().joinToString("") { "%02x".format(it) }
        return if (n == want.size && hex == want.sha256) null else "${want.name} does not match the manifest (size $n)"
    }
}
