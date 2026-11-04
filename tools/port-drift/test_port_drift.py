"""Tests for port-drift.py: python3 -m unittest discover -s tools/port-drift -p 'test_*.py'"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("port_drift", HERE / "port-drift.py")
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)


def literals(src, kotlin):
    return [t for _s, _e, t in pd.lex(src, kotlin)[1]]


class Lex(unittest.TestCase):
    def test_kotlin_template_with_nested_quotes_is_one_literal(self):
        src = 'val o = "-Dx=${keys.filter { it != k }.joinToString(",")}" // "-Dcommented=1"\nval p = "-Dy"\n'
        self.assertEqual(literals(src, True), ['-Dx=${keys.filter { it != k }.joinToString(",")}', "-Dy"])

    def test_kotlin_raw_string(self):
        self.assertEqual(literals('val r = """a "b" c"""\nval s = "-Dz"', True), ['a "b" c', "-Dz"])

    def test_commented_objc_options_are_skipped(self):
        src = '@[ @"-Da=1",\n  // @"-Db=1",\n  /* @"-Dc=1", */ @"-Dd=1" ];\n'
        self.assertEqual(literals(src, False), ["-Da=1", "-Dd=1"])

    def test_pragma_apostrophe_does_not_start_a_char_literal(self):
        src = '#pragma mark - the shell\'s options\nNSString *s = @"-De=1";\n'
        self.assertEqual(literals(src, False), ["-De=1"])

    def test_offsets_are_kept(self):
        src = 'a // c\n"x"'
        nostr, strings = pd.lex(src)
        self.assertEqual(len(nostr), len(src))
        self.assertEqual(src[strings[0][0]:strings[0][1]], '"x"')


class Options(unittest.TestCase):
    def test_kotlin_placeholders(self):
        consts = {"MAX_HEAP_MB": "512"}
        self.assertEqual(pd.placeholders("-Xmx${MAX_HEAP_MB}m", True, consts), "-Xmx512m")
        self.assertEqual(pd.placeholders("-Duser.home=$home", True, consts), "-Duser.home={home}")
        self.assertEqual(pd.placeholders('-Dk=${a.filter { it != b }.joinToString(",")}', True, consts), "-Dk={...}")

    def test_objc_placeholders(self):
        self.assertEqual(pd.placeholders("-Xmx%ldm", False, {}), "-Xmx{}m")
        self.assertEqual(pd.placeholders("-Dhome=%@", False, {}), "-Dhome={}")

    def test_kotlin_consts(self):
        src = 'private const val MAX_HEAP_MB = 512L\nconst val NAME = "x"\nval lower = 3\n'
        self.assertEqual(pd.kotlin_consts(src), {"MAX_HEAP_MB": "512", "NAME": "x"})

    def test_option_keys(self):
        self.assertEqual(pd.option_key("-Drunelite.menupeek.maxEntries=32"), ("-Drunelite.menupeek.maxEntries", "32"))
        self.assertEqual(pd.option_key("-Drunelite.bridge"), ("-Drunelite.bridge", ""))
        self.assertEqual(pd.option_key("-XX:+MirrorMappedCodeCache"), ("-XX:MirrorMappedCodeCache", "+"))
        self.assertEqual(pd.option_key("-XX:-UseCompressedClassPointers"), ("-XX:UseCompressedClassPointers", "-"))
        self.assertEqual(pd.option_key("-XX:ReservedCodeCacheSize=64m"), ("-XX:ReservedCodeCacheSize", "64m"))
        self.assertEqual(pd.option_key("-Xmx1024m"), ("-Xmx", "1024m"))
        self.assertEqual(pd.option_key("-Xlog:gc:stdout"), ("-Xlog", "gc:stdout"))
        self.assertEqual(pd.option_key("--add-opens=java.base/java.util=ALL-UNNAMED"),
                         ("--add-opens=java.base/java.util=ALL-UNNAMED", ""))

    def test_launched_computed_value_is_matched_and_shown(self):
        shown = pd.show_values([("{}m", "JVMLauncher.m:1752")], {"1024m"})
        self.assertIn("✓ = `1024m`", shown)
        self.assertNotIn("✓", pd.show_values([("32", "x.m:1")], {"14"}))


class Overrides(unittest.TestCase):
    def test_code_lines_drop_comments_and_blank_lines(self):
        a = "float x = 1.0; // one\n\n/* note */\nfloat y = 2.0;\n"
        b = "float x = 1.0; // uno\nfloat y = 2.0;\n"
        self.assertEqual(pd.code_lines(a), pd.code_lines(b))
        self.assertEqual(pd.changed(a, b), (0, 0))
        self.assertEqual(pd.changed(a, b.replace("2.0", "3.0")), (1, 1))

    def test_code_lines_keep_strings(self):
        self.assertNotEqual(pd.code_lines('s = "a // b";'), pd.code_lines('s = "a";'))


class JniTypes(unittest.TestCase):
    def test_java_params(self):
        self.assertEqual(pd.java_params("()V"), "")
        self.assertEqual(pd.java_params("(Ljava/lang/String;Z[I)V"), "String,boolean,int[]")
        self.assertEqual(pd.java_params("([Ljava/lang/String;J)V"), "String[],long")


ANDROID = r'''
static jmethodID midOpt(JNIEnv *env, jclass c, const char *name, const char *sig) {
    jmethodID m = env->GetStaticMethodID(c, name, sig);
    return m;
}
static bool registerDataPanel(JNIEnv *env, const char *clsName, const char *jsonGetter, DataPanel &p) {
    jclass c = env->FindClass(clsName);
    jclass g = (jclass) env->NewGlobalRef(c);
    jmethodID j = midOpt(env, g, jsonGetter, "()Ljava/lang/String;");
    p.cls = g;
    return true;
}
static bool bridgeInit(JNIEnv *env) {
    jclass mp = env->FindClass("net/runelite/client/headless/MenuPeekBridge");
    jclass mpg = (jclass) env->NewGlobalRef(mp);
    jmethodID snap = midOpt(env, mpg, "getSnapshot", "()Ljava/lang/String;");
    g_menuPeekCls = mpg;
    registerDataPanel(env, "net/runelite/client/headless/XpTrackerBridge", "getXpJson", g_xpPanel);
    registerDataPanel(env, "net/runelite/client/headless/LootTrackerBridge", "getLootJson", g_lootPanel);
    g_midLootReset = midOpt(env, g_lootPanel.cls, "resetAll", "()Ljava/lang/String;");
    return true;
}
static void later(JNIEnv *env) {
    jmethodID seq = midOpt(env, g_menuPeekCls, "getPublishSeq", "()J");
}
static void *jvmThreadMain(void *argp) {
    jclass cls = env->FindClass(internal.c_str());
    jmethodID mid = env->GetStaticMethodID(cls, "main", "([Ljava/lang/String;)V");
    return nullptr;
}
'''


class AndroidLookups(unittest.TestCase):
    def extract(self, src):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "jvm_bootstrap.cpp"
            p.write_text(src)
            return pd.android_lookups(p)

    def test_resolves_wrappers_helpers_and_globals(self):
        sites, skipped = self.extract(ANDROID)
        got = {(k, c.rsplit("/", 1)[-1], n) for k, c, n, _s, _w in sites if k != "class"}
        self.assertEqual(got, {
            ("smethod", "MenuPeekBridge", "getSnapshot"),
            ("smethod", "MenuPeekBridge", "getPublishSeq"),  # through the global g_menuPeekCls
            ("smethod", "XpTrackerBridge", "getXpJson"),     # each call site's class with its own getter
            ("smethod", "LootTrackerBridge", "getLootJson"),
            ("smethod", "LootTrackerBridge", "resetAll"),    # through registerDataPanel's p.cls = g
        })
        self.assertEqual({(n, s) for _w, n, s, _why in skipped}, {("-", "-"), ("main", "([Ljava/lang/String;)V")})

    def test_unresolvable_lookup_stops(self):
        with self.assertRaises(pd.InputError):
            self.extract("static void f(JNIEnv *env) {\n  jmethodID m = env->GetStaticMethodID(mystery, \"x\", \"()V\");\n}\n")

    def test_c_style_lookup_stops(self):
        src = ('static void f(JNIEnv *env) {\n  jclass c = env->FindClass("A");\n'
               '  jmethodID m = (*env)->GetMethodID(env, c, "x", "()V");\n}\n')
        with self.assertRaisesRegex(pd.InputError, r"jvm_bootstrap\.cpp:3: a JNI call not in the env->Name"):
            self.extract(src)

    def test_non_literal_name_outside_a_helper_stops(self):
        src = 'static void f(JNIEnv *env) {\n  jclass c = env->FindClass("A");\n  env->GetStaticMethodID(c, nm, "()V");\n}\n'
        with self.assertRaises(pd.InputError):
            self.extract(src)


class Repo(unittest.TestCase):
    def test_every_declaration_in_a_file_is_on_the_boot_path(self):
        found = pd.options_of("android")[0]  # JagexTokens.kt holds three
        for key in ("autologin", "autologin.manual", "autologin.world"):
            self.assertIn("-Drunelite.headless." + key, found)

    def test_report_on_this_tree(self):
        for _stager, tree in pd.RLHD.values():
            if not (pd.REPO / tree).is_dir():
                self.skipTest(f"{tree} isn't provisioned")
        text, summary = pd.build()
        for head in ("## 1. RLHD overrides", "## 2. JVM options", "## 3. Bridge bindings"):
            self.assertIn(head, text)
        self.assertTrue(summary.startswith("PORT_DRIFT "))
        # The boot-path scan doesn't mistake an option the native code tests for one it passes.
        self.assertNotIn("`-Drunelite.routec.smoke`", text.split("### Only Android sets it")[-1].split("###")[0])


if __name__ == "__main__":
    unittest.main()
