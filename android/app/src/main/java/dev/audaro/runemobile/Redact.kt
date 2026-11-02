package dev.audaro.runemobile

import org.json.JSONArray
import org.json.JSONObject

/**
 * Removes account details from a "Share logs" report before it leaves the phone: the literal tokens.json values,
 * the character's name, then generic shapes (web tokens, bearer headers, URL query secrets, key=value secrets,
 * emails, UUIDs). No Android types beyond org.json (the real one is on the test classpath), so RedactTest runs it
 * on the desktop JVM against tools/diagnostics/redaction-cases.txt and tokens-sample.json, the files the iOS
 * RMRedact.m is checked against too.
 */
object Redact {
    // The generic rules, in order. Keep them identical to iOS RMRedact.m. Bearer runs before key=value so
    // "Authorization: Bearer x" loses the token, not just the word "Bearer".
    private val RULES: List<Pair<Regex, String>> =
        listOf(
            // JSON web tokens (Jagex and RuneLite sign-in)
            Regex("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}(?:\\.[A-Za-z0-9_-]+)?") to "<token>",
            // Authorization: Bearer <token>
            Regex("(?i)\\b(bearer\\s+)[A-Za-z0-9._~+/=-]{8,}") to "$1<token>",
            // Query-string secrets in a logged URL (sign-in redirects carry one-time codes)
            Regex("(?i)([?&][a-z_]*(?:code|token|state|session|key)[a-z_]*=)[^&\\s\"'#]+") to "$1<redacted>",
            // key=value, key: value and "key":"value"
            Regex(
                "(?i)\\b((?:access|refresh|id|auth)[_-]?token|token|password|passwd|secret|session[_-]?id|session|" +
                    "authorization|api[_-]?key|character[_-]?id|account[_-]?id|display[_-]?name|user[_-]?name|" +
                    "jx_[a-z_]+)([\"']?\\s*[:=]\\s*[\"']?)([^\\s\"',;&}\\]]{4,})",
            ) to "$1$2<redacted>",
            // Emails
            Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") to "<email>",
            // UUIDs (session and account ids)
            Regex("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b") to "<uuid>",
        )

    private const val JOINERS = " _- "

    /**
     * [names] become `<player>` as whole words, ignoring case and treating space, underscore and hyphen as one;
     * [secrets] of six or more characters become `<redacted>` wherever they appear.
     */
    fun text(
        text: String,
        names: Collection<String>,
        secrets: Collection<String>,
    ): String {
        var s = text
        for (secret in secrets) {
            if (secret.length >= 6) s = s.replace(secret, "<redacted>")
        }
        for (name in names) {
            namePattern(name)?.let { s = it.replace(s, "<player>") }
        }
        for ((re, template) in RULES) s = re.replace(s, template)
        return s
    }

    // A name as a whole-word, any-case pattern in which space, underscore, hyphen and no-break space are one
    // character: OSRS shows "Iron Man", logs may say "Iron_Man" or "Iron Man".
    private fun namePattern(name: String): Regex? {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return null
        val body =
            trimmed
                .map { ch -> if (ch in JOINERS) "[ _\\u00a0-]" else Regex.escape(ch.toString()) }
                .joinToString("")
        return Regex("(?<![A-Za-z0-9])$body(?![A-Za-z0-9])", RegexOption.IGNORE_CASE)
    }

    // The key sets match iOS RMRedact collectAccount; tools/diagnostics/tokens-sample.json checks both.
    private val NAME_KEYS = setOf("chosen_display_name", "displayName", "display_name")
    private val SECRET_KEYS =
        setOf(
            "session_id",
            "chosen_account_id",
            "accountId",
            "account_id",
            "access_token",
            "refresh_token",
            "id_token",
            "otl_token",
            "userHash",
        )

    /**
     * Adds the names and literal secrets in a tokens.json to [names] and [secrets], wherever they sit (the chosen
     * character and every other one on the account). Values only; nothing from the file goes into a report.
     */
    fun collectAccount(
        json: String,
        names: MutableList<String>,
        secrets: MutableList<String>,
    ) {
        val stack = ArrayDeque<Any>()
        stack.add(JSONObject(json))
        while (stack.isNotEmpty()) {
            // (key, value) pairs; an array's items have no key, so a bare string in one is never collected.
            val entries: List<Pair<String?, Any?>> =
                when (val node = stack.removeLast()) {
                    is JSONArray -> {
                        (0 until node.length()).map { null to node.opt(it) }
                    }

                    is JSONObject -> {
                        node
                            .keys()
                            .asSequence()
                            .map { it to node.opt(it) }
                            .toList()
                    }

                    else -> {
                        emptyList()
                    }
                }
            for ((key, v) in entries) {
                when {
                    v is JSONObject -> stack.add(v)
                    v is JSONArray -> stack.add(v)
                    v !is String || v.isEmpty() -> Unit
                    key in NAME_KEYS -> names.add(v)
                    key in SECRET_KEYS -> secrets.add(v)
                }
            }
        }
    }
}
