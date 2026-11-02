package dev.audaro.runemobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Redact.kt against tools/diagnostics/redaction-cases.txt and tokens-sample.json, the same files the iOS
 * RMRedact.m is checked against (ios/dev-tools/diagnostics/test-redaction.sh), so both ports remove the same things.
 */
class RedactTest {
    @Test
    fun sharedCases() {
        val cases = fixture("redaction-cases.txt").readLines()
        val names = mutableListOf<String>()
        val secrets = mutableListOf<String>()
        val failures = mutableListOf<String>()
        var input: String? = null
        var count = 0
        for (line in cases) {
            when {
                line.startsWith("@name ") -> {
                    names += line.removePrefix("@name ")
                }

                line.startsWith("@secret ") -> {
                    secrets += line.removePrefix("@secret ")
                }

                line.startsWith("< ") -> {
                    input = line.removePrefix("< ")
                }

                line.startsWith("> ") -> {
                    val inLine = checkNotNull(input) { "'>' line with no '<' before it: $line" }
                    val want = line.removePrefix("> ")
                    val got = Redact.text(inLine, names, secrets)
                    count++
                    if (got != want) failures += "in:   $inLine\nwant: $want\ngot:  $got"
                    input = null
                }
            }
        }
        assertTrue("a '<' line has no '>' after it", input == null)
        assertTrue("no cases found", count > 0)
        assertEquals(failures.joinToString("\n\n"), 0, failures.size)
    }

    @Test
    fun accountWalk() {
        val want = fixture("tokens-sample.expect").readLines()
        val wantNames = want.filter { it.startsWith("name ") }.map { it.removePrefix("name ") }.toSet()
        val wantSecrets = want.filter { it.startsWith("secret ") }.map { it.removePrefix("secret ") }.toSet()
        assertTrue("tokens-sample.expect lists no names or secrets", wantNames.isNotEmpty() && wantSecrets.isNotEmpty())
        val names = mutableListOf<String>()
        val secrets = mutableListOf<String>()
        Redact.collectAccount(fixture("tokens-sample.json").readText(), names, secrets)
        assertEquals("names", wantNames, names.toSet())
        assertEquals("secrets", wantSecrets, secrets.toSet())
    }

    // Gradle runs unit tests from the module dir (android/app); walk up to the repo root.
    private fun fixture(name: String): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val f = File(dir, "tools/diagnostics/$name")
            if (f.isFile) return f
            dir = dir.parentFile
        }
        error("tools/diagnostics/$name not found above ${System.getProperty("user.dir")}")
    }
}
