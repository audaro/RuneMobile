package dev.audaro.runemobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64

// Keys are made here, never the real signing key: a test manifest signed with it could be replayed at players.
class GameUpdateRulesTest {
    private val shell = "0123456789abcdef0123456789abcdef01234567"
    private val now = 1_800_000_000_000L
    private val sha = "a".repeat(64)

    private fun keyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    private fun pin(k: KeyPair) = Base64.getEncoder().encodeToString(k.public.encoded)

    private fun sign(
        k: KeyPair,
        msg: ByteArray,
    ): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(k.private)
            update(msg)
            sign()
        }

    private fun file(
        name: String,
        url: String = "https://example.test/$name",
        size: Any = 100,
    ) = JSONObject()
        .put("name", name)
        .put("url", url)
        .put("size", size)
        .put("sha256", sha)

    private fun androidFiles() =
        JSONArray()
            .put(file("client-1.13.7-SNAPSHOT-gpu.jar"))
            .put(file("client-1.13.7-SNAPSHOT-rlhd.jar"))
            .put(file("probes.jar"))

    private fun set(
        port: String = "android",
        shell: String = this.shell,
        id: String = "android-7",
        files: JSONArray = androidFiles(),
    ) = JSONObject()
        .put("port", port)
        .put("shell", shell)
        .put("id", id)
        .put("runelite", "1.13.7-SNAPSHOT")
        .put("gameRevision", 243)
        .put("required", true)
        .put("files", files)

    private fun manifest(
        vararg sets: JSONObject,
        revision: Any = 7,
        expires: String = "2027-02-07T00:00:00Z",
    ) = JSONObject()
        .put("schema", 1)
        .put("kind", GameUpdateRules.KIND)
        .put("revision", revision)
        .put("expires", expires)
        .put("sets", JSONArray().apply { sets.forEach { put(it) } })

    private fun parse(
        m: JSONObject,
        bad: Set<String> = emptySet(),
        checkExpiry: Boolean = true,
        debug: Boolean = false,
        nowMs: Long = now,
    ) = GameUpdateRules.parse(
        m.toString().toByteArray(),
        "android",
        shell,
        GameUpdateRules.ANDROID_ROLES,
        bad,
        checkExpiry,
        nowMs,
        debug,
    )

    @Test
    fun signatureVerifiesUnderEitherPinAndNothingElse() {
        val current = keyPair()
        val spare = keyPair()
        val stranger = keyPair()
        val pins = listOf(pin(current), pin(spare))
        val msg = manifest(set()).toString().toByteArray()
        assertTrue(GameUpdateRules.verifySignature(msg, sign(current, msg), pins))
        assertTrue(GameUpdateRules.verifySignature(msg, sign(spare, msg), pins))
        assertFalse(GameUpdateRules.verifySignature(msg, sign(stranger, msg), pins))
        val tampered = msg.copyOf().also { it[10] = (it[10] + 1).toByte() }
        assertFalse(GameUpdateRules.verifySignature(tampered, sign(current, msg), pins))
        assertFalse(GameUpdateRules.verifySignature(msg, ByteArray(0), pins))
        assertFalse(GameUpdateRules.verifySignature(msg, ByteArray(GameUpdateRules.SIG_MAX + 1), pins))
    }

    @Test
    fun theAppsPinTwoDistinctP256Keys() {
        assertEquals(2, GameUpdate.PINS.size)
        assertEquals(2, GameUpdate.PINS.toSet().size)
        for (p in GameUpdate.PINS) {
            val der = Base64.getDecoder().decode(p)
            assertEquals(91, der.size) // a P-256 SubjectPublicKeyInfo
        }
    }

    @Test
    fun picksThisBuildsSet() {
        val p = parse(manifest(set(port = "ios", id = "ios-7"), set(shell = "f".repeat(40), id = "other"), set()))
        assertNotNull(p.set)
        val s = p.set!!
        assertEquals("android-7", s.id)
        assertEquals(7, s.manifestRevision)
        assertEquals(243, s.gameRevision)
        assertTrue(s.required)
        assertNull(s.pluginHubVersion)
        assertEquals("client-1.13.7-SNAPSHOT-gpu.jar", s.files.getValue("gpu").name)
        assertEquals(300L, s.totalBytes)
    }

    @Test
    fun noSetForThisBuildStillReportsTheRevision() {
        val p = parse(manifest(set(shell = "f".repeat(40))))
        assertNull(p.set)
        assertEquals(7, p.revision)
        assertEquals("manifest has no set for this build", p.why)
    }

    @Test
    fun expiryLimitsOffersOnly() {
        val m = manifest(set(), expires = "2020-01-01T00:00:00Z")
        assertEquals("manifest has expired", parse(m).why)
        assertEquals(7, parse(m).revision)
        assertNotNull(parse(m, checkExpiry = false).set)
    }

    @Test
    fun refusesTwoSetsForOneBuild() {
        assertEquals("manifest has two sets for this build", parse(manifest(set(), set(id = "android-8"))).why)
    }

    @Test
    fun refusesABadSet() {
        assertEquals("set android-7 is marked bad on this phone", parse(manifest(set()), bad = setOf("android-7")).why)
    }

    @Test
    fun topLevelMustBeExact() {
        assertNull(parse(manifest(set()).put("schema", 2)).set)
        assertNull(parse(manifest(set()).put("schema", true)).set)
        assertNull(parse(manifest(set()).put("kind", "something-else")).set)
        assertNull(parse(manifest(set(), revision = 0)).set)
        assertNull(parse(manifest(set(), revision = 1.5)).set)
        assertNull(parse(manifest(set(), expires = "soon")).set)
        assertEquals(
            "manifest is not a JSON object",
            GameUpdateRules
                .parse("[]".toByteArray(), "android", shell, GameUpdateRules.ANDROID_ROLES, emptySet(), true, now, false)
                .why,
        )
    }

    @Test
    fun everyRoleExactlyOnce() {
        val missing = JSONArray().put(file("client-1-gpu.jar")).put(file("probes.jar"))
        assertEquals("set does not name every jar", parse(manifest(set(files = missing))).why)
        val twice = androidFiles().put(file("client-2-gpu.jar"))
        assertEquals("a set file entry is invalid", parse(manifest(set(files = twice))).why)
        val stranger = androidFiles().put(file("evil.so"))
        assertEquals("a set file entry is invalid", parse(manifest(set(files = stranger))).why)
        val path = JSONArray().put(file("client-1-gpu.jar")).put(file("client-1-rlhd.jar")).put(file("../probes.jar"))
        assertEquals("a set file entry is invalid", parse(manifest(set(files = path))).why)
    }

    @Test
    fun fileEntriesAreChecked() {
        fun withProbes(f: JSONObject) = JSONArray().put(file("client-1-gpu.jar")).put(file("client-1-rlhd.jar")).put(f)
        assertNull(parse(manifest(set(files = withProbes(file("probes.jar", size = GameUpdateRules.FILE_MAX + 1))))).set)
        assertNull(parse(manifest(set(files = withProbes(file("probes.jar", size = 0))))).set)
        assertNull(parse(manifest(set(files = withProbes(file("probes.jar", size = 10.5))))).set)
        assertNull(parse(manifest(set(files = withProbes(file("probes.jar").put("sha256", "XYZ"))))).set)
    }

    @Test
    fun onlyHttpsExceptLoopbackInDebug() {
        fun with(url: String) =
            manifest(set(files = JSONArray().put(file("client-1-gpu.jar")).put(file("client-1-rlhd.jar")).put(file("probes.jar", url))))
        assertNull(parse(with("http://127.0.0.1:8765/probes.jar")).set)
        assertNotNull(parse(with("http://127.0.0.1:8765/probes.jar"), debug = true).set)
        assertNotNull(parse(with("http://localhost:8765/probes.jar"), debug = true).set)
        assertNull(parse(with("http://example.test/probes.jar"), debug = true).set)
        assertNull(parse(with("file:///sdcard/probes.jar"), debug = true).set)
        assertNull(parse(with("not a url"), debug = true).set)
    }

    @Test
    fun hubPinAndRequiredAreTyped() {
        assertEquals("1.13.6", parse(manifest(set().put("pluginHubVersion", "1.13.6"))).set?.pluginHubVersion)
        assertNull(parse(manifest(set().put("pluginHubVersion", "1.13.6; rm -rf"))).set)
        assertNull(parse(manifest(set().put("required", "yes"))).set)
        assertFalse(parse(manifest(set().apply { remove("required") })).set!!.required)
    }

    @Test
    fun fileMismatchChecksSizeAndHash() {
        val f = File.createTempFile("game-update", ".jar")
        try {
            val bytes = "hello game update".toByteArray()
            f.writeBytes(bytes)
            val good = GameUpdateRules.FileEntry("probes.jar", "https://x/", bytes.size.toLong(), GameUpdateRules.sha256Hex(bytes))
            assertNull(GameUpdateRules.fileMismatch(f, good))
            val wrongHash = GameUpdateRules.FileEntry("probes.jar", "https://x/", bytes.size.toLong(), sha)
            assertNotNull(GameUpdateRules.fileMismatch(f, wrongHash))
            f.appendBytes(byteArrayOf(1))
            assertNotNull(GameUpdateRules.fileMismatch(f, good))
            assertEquals("probes.jar is missing", GameUpdateRules.fileMismatch(File(f.path + ".gone"), good))
        } finally {
            f.delete()
        }
    }
}
