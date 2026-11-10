// Detekt's shape rules are relaxed for this file only: each step of the boot pick and the download is an early return
// with its own log reason (the iOS twin, RMGameUpdate.m, reads the same way), and the network code catches every
// exception so a surprise on the executor can never skip the callback a waiting card depends on.
@file:Suppress(
    "ReturnCount",
    "CyclomaticComplexMethod",
    "NestedBlockDepth",
    "TooManyFunctions",
    "TooGenericExceptionCaught",
    "LoopWithTooManyJumpStatements",
)

package dev.audaro.runemobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * New game files without a reinstall (docs/GAME-UPDATES-PLAN.md, local). When the game moves to a new revision, the
 * Mac publishes a signed manifest naming a new set of the three jars this app boots (client-<ver>-gpu,
 * client-<ver>-rlhd, probes), built for this exact source commit. This fetches and verifies the manifest, downloads
 * and hash-checks a set, and at each boot picks the set to run: the newest verified download, or the jars from the
 * APK. A set that twice fails to reach the engine's first frame is marked bad and the APK's jars run again. The
 * rules are in [GameUpdateRules]; ios/app/RuneMobile/RMGameUpdate.m is the iOS twin.
 *
 * On disk, in filesDir/game-update/:
 *   sets/<id>/        a verified set: the jars plus the manifest.json and manifest.sig it came from
 *   sets/<id>.partial a download in progress (removed at boot unless this process is writing it)
 *   current           the id of the set the next boot uses
 *   boot-armed        "<id> <n>": n boots of <id> started and none reached the first frame yet
 *   bad-sets          ids that failed [BAD_AFTER_BOOTS] boots in a row, one per line
 *   highest-revision  the highest manifest revision accepted (an older one is a replay)
 * The running process never touches its own set's directory: a new set lands in its own directory and only the next
 * boot switches to it, so a jar the VM has open is never replaced under it.
 */
object GameUpdate {
    private const val MANIFEST_URL = "https://github.com/audaro/runemobile/releases/download/game-update/game-update.json"
    private const val PORT = "android"

    // SubjectPublicKeyInfo DER, base64: current, then spare (tools/game-update/keygen.sh --pins). The same two as
    // RMGameUpdate.m; make-manifest.py refuses to sign with a key that isn't the first pin of both.
    val PINS =
        listOf(
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEN7ZacJwhId8Qd9r4CN4/G08j2Px7uus+6jTmHA+RM/oYyiqRSslIpFFqW0JWqCSyqaLcg2LmjgFawSYxOY+rNQ==",
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDcsQ0kW0or/4l2UY5GzmxNUters14AkcDjfjrWkTyu3V64jLPFVC7WSNDCbLFuoGxRn1h+gY2upQndhpsfXlPA==",
        )
    private const val BAD_AFTER_BOOTS = 2
    private const val BAD_LIST_MAX = 32

    enum class CheckResult(
        val label: String,
    ) {
        DISABLED("off"), // this build takes no game updates (not a clean, stamped release commit)
        FAILED("failed"), // network or verification failure: nothing is known
        NO_SET("no set"), // a valid manifest has no usable set for this build: only a new app build helps
        CURRENT("up to date"), // the newest set for this build is already installed
        OFFER("offer"), // a newer set is available to download
    }

    private val lock = Any() // every read and write of the game-update dir
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val net = Executors.newSingleThreadExecutor { r -> Thread(r, "rm-game-update").apply { isDaemon = true } }

    @Volatile private var base: File? = null

    @Volatile private var devShell: String? = null

    @Volatile private var devUrl: String? = null

    @Volatile var devRecheckSeconds: Long = 0
        private set

    @Volatile private var booted = false

    @Volatile private var settled = false

    /** The set this process booted, or null for the APK's jars (or before boot). */
    @Volatile var bootedSetId: String? = null
        private set

    @Volatile var downloading = false
        private set

    /** The running download's bytes so far and total, for a card that polls. */
    @Volatile var downloadDone = 0L
        private set

    @Volatile var downloadTotal = 0L
        private set

    @Volatile private var partialInFlight: String? = null

    @Volatile private var lastCheck = "not checked"

    @Volatile private var launchCheckStarted = false
    private val checkWaiters = mutableListOf<(CheckResult, GameUpdateRules.GameSet?, String) -> Unit>() // main only

    /** Idempotent; call before anything else. Debug builds read their test overrides from marker files here. */
    fun init(ctx: Context) {
        if (base != null) return
        if (BuildConfig.DEBUG) {
            val ext = ctx.getExternalFilesDir(null)

            fun marker(name: String) = runCatching { File(ext, name).readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() }
            // Pretend to be a released build, so the emulator can take a set published for that commit, and read
            // the manifest from a local test server (adb reverse tcp:8765 tcp:8765).
            devShell = marker("game-update-shell")
            devUrl = marker("game-update-url")
            devRecheckSeconds = marker("game-update-recheck")?.toLongOrNull() ?: 0
        }
        base = File(ctx.filesDir, "game-update")
    }

    /** The commit this build came from (BuildConfig.SOURCE_COMMIT), "-dirty" suffixed for a modified tree. */
    val shellCommit: String get() = devShell ?: BuildConfig.SOURCE_COMMIT

    /** Whether this build takes game updates at all: a clean 40-hex commit stamp (or a debug override). */
    val enabled: Boolean get() = GameUpdateRules.isCommit(shellCommit)

    private fun dir(): File = checkNotNull(base) { "GameUpdate.init not called" }

    private fun file(name: String) = File(dir(), name)

    private fun setsDir() = File(dir(), "sets")

    private fun readString(name: String): String = runCatching { file(name).readText().trim() }.getOrDefault("")

    private fun writeString(
        name: String,
        s: String,
    ) {
        setsDir().mkdirs()
        val tmp = file("$name.tmp")
        tmp.writeText(s)
        if (!tmp.renameTo(file(name))) {
            file(name).writeText(s)
            tmp.delete()
        }
    }

    private fun badSets(): Set<String> = readString("bad-sets").lines().filter { it.isNotEmpty() }.toSet()

    private fun markBad(id: String) {
        val lines = readString("bad-sets").lines().filter { it.isNotEmpty() }.toMutableList()
        if (id !in lines) lines.add(id)
        while (lines.size > BAD_LIST_MAX) lines.removeAt(0)
        writeString("bad-sets", lines.joinToString("\n") + "\n")
    }

    private fun highestRevision(): Int = readString("highest-revision").toIntOrNull() ?: 0

    /** "<id> <n>" -> (id, n), or null. */
    private fun cookie(): Pair<String, Int>? {
        val parts = readString("boot-armed").split(" ")
        return if (parts.size == 2 && parts[0].isNotEmpty()) parts[0] to (parts[1].toIntOrNull() ?: 0) else null
    }

    private fun parse(
        data: ByteArray,
        checkExpiry: Boolean,
    ) = GameUpdateRules.parse(
        data,
        PORT,
        shellCommit,
        GameUpdateRules.ANDROID_ROLES,
        badSets(),
        checkExpiry,
        System.currentTimeMillis(),
        BuildConfig.DEBUG,
    )

    /** sets/<id>/manifest.json + .sig, verified for this build, or null with why. Under [lock]. */
    private fun installedSet(id: String): Pair<GameUpdateRules.GameSet?, String?> {
        val d = File(setsDir(), id)
        val json = runCatching { File(d, "manifest.json").readBytes() }.getOrNull()
        val sig = runCatching { File(d, "manifest.sig").readBytes() }.getOrNull()
        if (json == null || sig == null || json.size > GameUpdateRules.MANIFEST_MAX) return null to "installed set has no manifest"
        if (!GameUpdateRules.verifySignature(json, sig, PINS)) return null to "installed manifest signature does not verify"
        // No expiry check at boot: expiry limits what is offered, not a set already verified and installed.
        val p = parse(json, checkExpiry = false)
        val set = p.set ?: return null to p.why
        if (set.id != id) return null to "installed manifest names a different set"
        set.dir = d
        return set to null
    }

    // ---- Boot ----

    /**
     * On the boot thread, before the VM starts: the installed set to boot (fully re-verified), or null for the APK's
     * jars. A set whose last boots never reached a frame is marked bad here.
     */
    fun setForBoot(log: (String) -> Unit): GameUpdateRules.GameSet? {
        val lines = mutableListOf<String>()
        val set = synchronized(lock) { bootSelect(lines) }
        lines.forEach(log)
        return set
    }

    private fun bootSelect(lines: MutableList<String>): GameUpdateRules.GameSet? {
        booted = true
        if (!enabled) {
            lines.add("[game-update] off: this build's commit is $shellCommit, so it boots the APK's jars")
            return null
        }
        val current = readString("current")
        var set: GameUpdateRules.GameSet? = null
        if (current.isNotEmpty()) {
            val (installed, whyInstalled) = installedSet(current)
            var why = whyInstalled
            set = installed
            val c = cookie()
            if (set != null && c?.first == current && c.second >= BAD_AFTER_BOOTS) {
                markBad(current)
                lines.add(
                    "[game-update] set $current started ${c.second} times without reaching the first frame: marked bad, " +
                        "booting the APK's jars",
                )
                set = null
            } else if (set != null) {
                for (role in GameUpdateRules.ANDROID_ROLES.keys) {
                    why = GameUpdateRules.fileMismatch(set!!.jar(role), set.files.getValue(role))
                    if (why != null) {
                        set = null
                        break
                    }
                }
            }
            if (set == null) {
                if (why != null) lines.add("[game-update] not booting set $current: $why")
                file("current").delete()
                file("boot-armed").delete()
            } else if (c != null && c.first != current) {
                file("boot-armed").delete()
            }
        }
        // Remove every other set: the one the last process ran, leftovers, a failed one. Keep only a download this
        // process is writing right now.
        setsDir().listFiles()?.forEach { f ->
            if (f.name != set?.id && f.name != partialInFlight) f.deleteRecursively()
        }
        if (set != null) {
            bootedSetId = set.id
            lines.add(
                "[game-update] booting set ${set.id} (game revision ${set.gameRevision}, RuneLite ${set.runelite}, " +
                    "manifest ${set.manifestRevision}), every jar verified",
            )
        } else {
            lines.add("[game-update] booting the APK's jars")
        }
        return set
    }

    /** The VM is up on [set]: count the boot. */
    fun armBoot(set: GameUpdateRules.GameSet) {
        synchronized(lock) {
            val c = cookie()
            val n = if (c?.first == set.id) c.second else 0
            writeString("boot-armed", "${set.id} ${n + 1}")
        }
    }

    /** The booted set works (first frame, or the engine reached the game servers): clear the cookie. Idempotent. */
    fun settleBoot() {
        if (settled || base == null) return
        settled = true
        // Its own thread, not [net]: behind a 40 MB download the clear could wait minutes, and a player who closes
        // the app meanwhile would leave the boot counted against a set that works.
        Thread({
            synchronized(lock) {
                val c = cookie()
                if (c != null && c.first == bootedSetId) file("boot-armed").delete()
            }
        }, "rm-game-update-settle").start()
    }

    /** A set newer than the one this process runs is installed: the next launch boots it. */
    val readyForNextLaunch: Boolean
        get() =
            base != null &&
                synchronized(lock) {
                    val current = readString("current")
                    booted && current.isNotEmpty() && current != (bootedSetId ?: "")
                }

    /** One line for Share logs: what booted, what is installed, the last check. */
    val statusLine: String
        get() {
            val current = if (base == null) "" else synchronized(lock) { readString("current") }
            return "${if (enabled) "on" else "off (dev build)"} | build ${shellCommit.take(12)} | " +
                "booted ${if (booted) bootedSetId ?: "APK jars" else "not yet"} | installed ${current.ifEmpty { "none" }} | " +
                "last check: $lastCheck"
        }

    // ---- Network ----

    private fun manifestUrl(): String = devUrl ?: MANIFEST_URL

    private fun open(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 20_000
            useCaches = false
            instanceFollowRedirects = true // GitHub release assets redirect to their CDN (https to https only)
        }

    /** A small file, whole, or null with why. */
    private fun fetch(
        url: String,
        max: Int,
    ): Pair<ByteArray?, String?> =
        try {
            val c = open(url)
            try {
                val status = c.responseCode
                if (status != 200) {
                    null to "HTTP $status for ${url.substringAfterLast('/')}"
                } else {
                    val out = java.io.ByteArrayOutputStream()
                    c.inputStream.use { input ->
                        val buf = ByteArray(16 * 1024)
                        while (true) {
                            val r = input.read(buf)
                            if (r < 0) break
                            out.write(buf, 0, r)
                            if (out.size() > max) break
                        }
                    }
                    val b = out.toByteArray()
                    if (b.isEmpty() || b.size > max) null to "${url.substringAfterLast('/')} is ${b.size} bytes" else b to null
                }
            } finally {
                c.disconnect()
            }
        } catch (e: Exception) {
            null to (e.message ?: e.javaClass.simpleName)
        }

    /** Ask for a newer set for this build. [cb] runs on the main thread; a call while one is in flight joins it. */
    fun check(cb: (CheckResult, GameUpdateRules.GameSet?, String) -> Unit) {
        if (!enabled || base == null) {
            main.post { cb(CheckResult.DISABLED, null, "this build takes no game updates") }
            return
        }
        main.post {
            checkWaiters.add(cb)
            if (checkWaiters.size > 1) return@post
            net.execute {
                val (r, set, detail) = runCheck()
                main.post {
                    lastCheck = "${r.label} ($detail)"
                    val waiters = checkWaiters.toList()
                    checkWaiters.clear()
                    waiters.forEach { it(r, set, detail) }
                }
            }
        }
    }

    private fun runCheck(): Triple<CheckResult, GameUpdateRules.GameSet?, String> {
        val url = manifestUrl()
        val (json, why) = fetch(url, GameUpdateRules.MANIFEST_MAX)
        if (json == null) return Triple(CheckResult.FAILED, null, why ?: "no manifest")
        val (sig, why2) = fetch("$url.sig", GameUpdateRules.SIG_MAX)
        if (sig == null) return Triple(CheckResult.FAILED, null, why2 ?: "no signature")
        if (!GameUpdateRules.verifySignature(json, sig, PINS)) return Triple(CheckResult.FAILED, null, "manifest signature does not verify")
        return synchronized(lock) {
            val p = parse(json, checkExpiry = true)
            val highest = highestRevision()
            when {
                p.revision in 1 until highest -> {
                    Triple(CheckResult.FAILED, null, "manifest revision ${p.revision} is older than $highest")
                }

                else -> {
                    if (p.revision > highest) writeString("highest-revision", p.revision.toString())
                    val set = p.set
                    when {
                        set == null -> {
                            Triple(if (p.revision > 0) CheckResult.NO_SET else CheckResult.FAILED, null, p.why ?: "no set")
                        }

                        readString("current") == set.id -> {
                            Triple(CheckResult.CURRENT, null, "set ${set.id} is installed")
                        }

                        else -> {
                            set.manifestBytes = json
                            set.signature = sig
                            val mb = "%.1f".format(java.util.Locale.US, set.totalBytes / 1048576.0)
                            Triple(
                                CheckResult.OFFER,
                                set,
                                "set ${set.id} (game revision ${set.gameRevision}, $mb MB${if (set.required) ", required" else ""})",
                            )
                        }
                    }
                }
            }
        }
    }

    /** Download, verify and install [set] for the next boot. Callbacks run on the main thread. */
    fun download(
        set: GameUpdateRules.GameSet,
        progress: ((Long, Long) -> Unit)?,
        done: (Boolean, String) -> Unit,
    ) {
        if (downloading || set.manifestBytes == null || set.signature == null) {
            main.post { done(false, if (downloading) "a download is already running" else "set did not come from a check") }
            return
        }
        downloading = true
        downloadDone = 0
        downloadTotal = set.totalBytes
        net.execute {
            val partialName = "${set.id}.partial"
            val partial = File(setsDir(), partialName)
            synchronized(lock) {
                partialInFlight = partialName
                partial.deleteRecursively()
                partial.mkdirs()
            }
            var why: String? = null
            var before = 0L
            for ((_, f) in set.files) {
                why = downloadFile(f, File(partial, f.name), before, set.totalBytes, progress)
                if (why != null) break
                before += f.size
            }
            val ok =
                synchronized(lock) {
                    if (why == null) why = install(set, partial)
                    if (why != null) partial.deleteRecursively()
                    partialInFlight = null
                    why == null
                }
            main.post {
                downloading = false
                done(ok, if (ok) "set ${set.id} installed" else why ?: "failed")
            }
        }
    }

    /** One file, hashed as it streams. Null on success, else why. On [net]. */
    private fun downloadFile(
        f: GameUpdateRules.FileEntry,
        dest: File,
        before: Long,
        total: Long,
        progress: ((Long, Long) -> Unit)?,
    ): String? {
        return try {
            val c = open(f.url)
            try {
                val status = c.responseCode
                if (status != 200) return "HTTP $status for ${f.name}"
                val md = MessageDigest.getInstance("SHA-256")
                var n = 0L
                var lastTick = 0L
                c.inputStream.use { input ->
                    dest.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val r = input.read(buf)
                            if (r < 0) break
                            n += r
                            if (n > f.size) return "${f.name} is larger than the manifest says"
                            md.update(buf, 0, r)
                            out.write(buf, 0, r)
                            downloadDone = before + n
                            val now = SystemClock.uptimeMillis()
                            if (progress != null && now - lastTick >= 250) {
                                lastTick = now
                                val got = before + n
                                main.post { progress(got, total) }
                            }
                        }
                    }
                }
                val hex = md.digest().joinToString("") { "%02x".format(it) }
                if (n != f.size || hex != f.sha256) "${f.name} does not match the manifest (size $n)" else null
            } finally {
                c.disconnect()
            }
        } catch (e: Exception) {
            e.message ?: e.javaClass.simpleName
        }
    }

    /** Under [lock]: the partial dir holds every verified jar. Add the manifest, move it into place, point at it. */
    private fun install(
        set: GameUpdateRules.GameSet,
        partial: File,
    ): String? {
        runCatching {
            File(partial, "manifest.json").writeBytes(set.manifestBytes!!)
            File(partial, "manifest.sig").writeBytes(set.signature!!)
        }.onFailure { return "could not write the manifest beside the jars" }
        val final = File(setsDir(), set.id)
        if (set.id == bootedSetId) {
            // This process runs from that directory already: never touch it, just point at it again.
            partial.deleteRecursively()
        } else {
            final.deleteRecursively()
            if (!partial.renameTo(final)) return "could not move the set into place"
        }
        writeString("current", set.id)
        // A cookie for some other set means nothing for this one.
        val c = cookie()
        if (c != null && c.first != (bootedSetId ?: "")) file("boot-armed").delete()
        return null
    }

    /** At launch, once per process: check, and download any offer in the background for the next boot. */
    fun startLaunchCheck(log: (String) -> Unit) {
        if (launchCheckStarted) return
        launchCheckStarted = true
        if (!enabled) {
            log("[game-update] off: build $shellCommit is not a clean release commit")
            return
        }
        check { r, offer, detail ->
            log("[game-update] launch check: $detail")
            if (r == CheckResult.OFFER && offer != null && !downloading) {
                log("[game-update] downloading set ${offer.id} for the next launch")
                download(offer, null) { ok, d -> log("[game-update] download ${if (ok) "done" else "failed"}: $d") }
            }
        }
    }
}
