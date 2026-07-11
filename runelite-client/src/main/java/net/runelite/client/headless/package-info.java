/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * The shared, headless bridge between real RuneLite and the two native mobile shells (iOS Objective-C,
 * Android Kotlin/C++). Everything here is plain Java on the embedded on-device OpenJDK; a change to a
 * public-static method or a hand-rolled JSON payload key/shape hits <b>both</b> ports, so the cross-port
 * contract gate ({@code tools/shared-contract/}) pins those surfaces.
 *
 * <h2>Threading invariant — read before you "fix" the JNI plumbing (THREAD-DOC / finding B-A6)</h2>
 *
 * The threading here looks under-synchronized on purpose. It is sound because of one discipline that is NOT
 * obvious from any single call site, so it is written down here to stop a well-meaning contributor from
 * "hardening" it into a deadlock or a use-after-free:
 *
 * <ol>
 *   <li><b>Per-thread daemon attach; a {@code JNIEnv} is never shared across threads.</b> Each OS thread that
 *   calls into the HotSpot VM attaches itself lazily via {@code AttachCurrentThreadAsDaemon}
 *   ({@code bridgeEnvAttach()} in Android's {@code jvm_bootstrap.cpp}; {@code ensureBridge()} in iOS's
 *   {@code JVMLauncher.m}) and is <em>never detached</em> (daemon attach — the thread outlives the call). The
 *   returned {@code JNIEnv*} is valid only on the thread that obtained it and must never be cached in a
 *   file-scope global or handed to another thread. Only the resolved {@code jclass}/{@code jmethodID} handles
 *   (which are process-global) are cached (once, on the boot thread, as {@code NewGlobalRef}s).</li>
 *
 *   <li><b>All engine/HotSpot mutation funnels to the single render (client) thread.</b> RuneLite's client
 *   state — game state, camera, widgets, the frame buffer — is client-thread-only. The native UI thread never
 *   touches the engine directly: input arrives as intents ({@code onClick}/{@code onTouch}/{@code onMove}/
 *   {@code onWheel}/{@code onCameraDrag}/{@code onText}/{@code onKeyStroke}) that are enqueued and <em>drained
 *   on the client thread</em> (e.g. {@code JavaBridge}'s tap/camera tick). Snapshots the shells poll
 *   ({@code MobileChromeBridge}, {@code MobileUiBridge}, {@code HudVeneerBridge}, …) are built on the client
 *   thread and published as an immutable {@code volatile} reference; native reads the latest reference with no
 *   lock. The engine is therefore only ever entered from one thread.</li>
 *
 *   <li><b>Values cross the boundary as copies, not shared references.</b> Strings and arrays read from the
 *   HotSpot env are copied out ({@code GetStringUTFChars} / {@code Get*ArrayElements} or the frame's
 *   {@code GetPrimitiveArrayCritical} blit) before the native side uses them, so no Java-heap pointer escapes
 *   the critical window onto another thread.</li>
 * </ol>
 *
 * <p>Consequences a future edit must preserve: do not cache or share a {@code JNIEnv} across threads; do not
 * call an engine/bridge method that reads client state from the native UI thread (enqueue an intent instead);
 * and keep the {@code GetPrimitiveArrayCritical} frame window tight (no JNI calls that could block inside it).
 * The apparent lack of locks around the snapshot is correct — single writer (client thread), single
 * {@code volatile} publish, many lock-free readers.</p>
 */
package net.runelite.client.headless;
