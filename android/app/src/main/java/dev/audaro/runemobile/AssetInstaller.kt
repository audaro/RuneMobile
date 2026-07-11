package dev.audaro.runemobile

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Unpacks the embedded JRE tree + jars from APK assets to filesDir on first launch.
 *
 * Staging is ASSETS-ONLY: the whole bionic JRE — including its native libs under jre/lib/ (libjvm.so and its
 * siblings) — plus the client/probe jars ship as APK assets and are unpacked here. The native host then
 * dlopens libjvm.so by absolute path out of this filesDir tree (see MainActivity.bootJvm and
 * jvm_bootstrap.cpp's preloadJreLibs). Only our own JNI lib (librunemobile.so) lives in jniLibs and is loaded
 * via System.loadLibrary. NB: dlopen from writable app storage is nominally restricted for API 29+ targets —
 * it works on the emulator; this must be confirmed on a real device (PORT-PHASING §5 Q11), moving the JRE .so
 * set into a native-lib dir if a hardened device rejects it.
 */
object AssetInstaller {
    private const val TAG = "AssetInstaller"

    /**
     * BOOT-1: thrown before an unpack that cannot fit. The caller (MainActivity.bootJvm) turns this into a
     * "free up storage" card instead of the generic boot-failure copy — it's the one boot error the user can
     * actually fix themselves.
     */
    class InsufficientSpaceException(
        val neededMb: Long,
        val freeMb: Long,
    ) : RuntimeException("need ~${neededMb}MB free to unpack the runtime, only ${freeMb}MB available")

    // PERF-COLD-START-06: two INDEPENDENT re-unpack gates so a jar update doesn't re-copy the whole tree.
    //  - BASE (.installed-base) covers the embedded JRE / native libs under jvm/jre (~110 MB modules + .so). Bump
    //    by hand when those change — rare.
    //  - the runtime.tag content hash (.installed-tag) covers the staged jars + runtime.tag that
    //    tools/stage-mobile-runtime.sh writes — the common per-update change.
    // A jar-only update bumps the tag but not BASE, so only the ~38 MB of jars re-copy; the 110 MB JRE stays put
    // (the old single "<BASE>-<tag>" key re-wiped + recopied the entire ~198 MB tree on every jar bump).
    private const val BASE = "v5"

    /**
     * Returns the JAVA_HOME path (filesDir/jvm/jre).
     *
     * [onProgress] (optional) is invoked ONLY on the first-install / re-unpack path with a coarse 0..100 percent
     * as each unpacked subtree finishes copying — the cold-start splash uses it for an "Unpacking… N%" line. On
     * the fast path (already installed) it is never called. The callback runs on the calling (boot) thread, so the
     * consumer must marshal to the UI thread itself.
     */
    fun ensureInstalled(
        ctx: Context,
        onProgress: ((Int) -> Unit)? = null,
    ): File {
        val root = File(ctx.filesDir, "jvm")
        val jreDir = File(root, "jre")
        val baseMarker = File(root, ".installed-base")
        val tagMarker = File(root, ".installed-tag")
        val wantTag = bundledTag(ctx)
        // The JRE re-unpacks when BASE changes (or it's missing); the jars re-unpack when the content tag changes.
        val baseStale = readMarker(baseMarker) != BASE || !jreDir.exists()
        val tagStale = readMarker(tagMarker) != wantTag
        if (!baseStale && !tagStale) return jreDir // fast path — nothing to do

        Log.i(TAG, "runtime unpack: baseStale=$baseStale (BASE=$BASE) tagStale=$tagStale (tag=$wantTag) -> $root")
        root.mkdirs()
        // BOOT-1 precheck: a mid-copy ENOSPC leaves a torn tree (recoverable via the marker gates, but only
        // after the user frees space and relaunches blind). Fail up front with an actionable error instead.
        // The full tree is ~198 MB (JRE ~110 + jars ~38 + headroom); a jar-only refresh needs far less.
        val neededMb = if (baseStale) 250L else 80L
        val freeMb = root.usableSpace / (1024 * 1024)
        if (freeMb < neededMb) {
            Log.e(TAG, "runtime unpack blocked: ${freeMb}MB free, need ~${neededMb}MB")
            throw InsufficientSpaceException(neededMb, freeMb)
        }
        // Wipe only what's being replaced so old and new never mix — the JRE subtree when BASE changed, and the
        // stale non-jre files (old jars) when the tag changed; the markers + the untouched gate are preserved.
        if (baseStale) jreDir.deleteRecursively()
        if (tagStale) {
            root.listFiles()?.forEach { f ->
                if (f.name != "jre" && f != baseMarker && f != tagMarker) f.deleteRecursively()
            }
        }
        // Copy each gate, writing its marker ONLY after that gate's copy fully succeeds — so an unpack killed
        // mid-jars doesn't re-copy the (already-landed) 110 MB JRE on retry, and a torn copy never leaves a
        // matching marker (an interrupted gate just re-runs next launch). Coarse per-subtree progress.
        val nonJre =
            ctx.assets
                .list("jvm")
                ?.filter { it != "jre" }
                .orEmpty()
        val total = ((if (baseStale) 1 else 0) + (if (tagStale) nonJre.size else 0)).coerceAtLeast(1)
        var done = 0
        onProgress?.invoke(0)
        if (baseStale) {
            copyAssetDir(ctx, "jvm/jre", jreDir)
            baseMarker.writeText(BASE)
            done++
            onProgress?.invoke(done * 100 / total)
        }
        if (tagStale) {
            for (child in nonJre) {
                copyAssetDir(ctx, "jvm/$child", File(root, child))
                done++
                onProgress?.invoke(done * 100 / total)
            }
            tagMarker.writeText(wantTag) // the jars share one content tag — mark done only once all have landed
        }
        return jreDir
    }

    private fun readMarker(f: File): String? = if (f.exists()) f.readText().trim() else null

    /** The staged content tag shipped in the bundle (jvm/runtime.tag); "untagged" if staging didn't write it. */
    private fun bundledTag(ctx: Context): String =
        runCatching {
            ctx.assets
                .open("jvm/runtime.tag")
                .bufferedReader()
                .use { it.readText().trim() }
        }.getOrElse {
            Log.w(TAG, "jvm/runtime.tag missing from bundle — run tools/stage-mobile-runtime.sh")
            "untagged"
        }

    private fun copyAssetDir(
        ctx: Context,
        assetPath: String,
        dest: File,
    ) {
        val children = ctx.assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            // leaf: a file
            dest.parentFile?.mkdirs()
            ctx.assets.open(assetPath).use { input ->
                // 1 MB buffer (vs Kotlin's default 8 KB) — the unpack streams a ~198 MB tree on first launch,
                // so a larger buffer cuts the syscall count dramatically (PERF-COLD-START-01).
                dest.outputStream().use { input.copyTo(it, 1 shl 20) }
            }
            return
        }
        dest.mkdirs()
        for (child in children) {
            copyAssetDir(ctx, "$assetPath/$child", File(dest, child))
        }
    }
}
