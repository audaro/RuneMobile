// runelite-ios — StikDebug JIT script for the on-device HotSpot (jre21, iOS 26 TXM)
// ---------------------------------------------------------------------------------
// Assign this to RuneMobile in StikDebug. It services HotSpot's one code-cache
// reservation so the JVM can generate executable code on a TXM device, then
// DETACHES so the dense-compile phase runs with no debugger holding the task ports.
//
// Lifecycle (Amethyst parity — detach after the first brk):
//   1. vAttach (grants CS_DEBUGGED → JIT permission, which persists after detach).
//   2. Service the single brk #0x69 (BreakGetJITMapping): our jre21's libjvm reserves
//      the whole ReservedCodeCacheSize (64 MB) in ONE call at VM init —
//      `char* BreakGetJITMapping(size_t bytes)` == `brk #0x69; ret` (size in x0, RX
//      address returned in x0). We allocate an RX region of `size`, wire it up via
//      prepare_memory_region, and return its address — HotSpot mirrors it RW to write
//      code and executes the RX view. (libjvm is patched so the brk path is taken.)
//   3. Detach (`D`). The RX mapping and CS_DEBUGGED persist; HotSpot runs the
//      dense-compile phase debugger-free.
//
// UPDATE 18 — same-session login (WebKit) robustness:
//   When the Jagex login WKWebView was opened earlier this app session, the FIRST
//   brk #0x69 (CodeCache::initialize) crashes the JVM (fatal SIGTRAP, PC left ON the
//   brk → it was never serviced). Diagnosis: with WebKit resident the process has many
//   more threads, so the stop can be reported on a thread OTHER than the one sitting at
//   the brk; the old fast-path check ("is THE STOPPING thread at a brk?") then misses
//   and the brk is forwarded as a fatal signal. Fix is ADDITIVE: the proven fast path
//   (stopping thread is at brk #0x69 → service → detach) is unchanged, so a clean
//   launch behaves byte-for-byte as before; only when the stopping thread is NOT at a
//   brk (which never happens on a clean launch) do we now scan EVERY thread for the
//   brk #0x69 and service it, instead of forwarding. Degrades safely to the old
//   behaviour if the thread-query packets aren't supported. Verbose per-stop logging.
//
// Uses only StikDebug builtins (get_pid, send_command, prepare_memory_region, log),
// the GDB remote protocol, and the AArch64 BRK encoding.

const pid = get_pid();
let served = 0, forwarded = 0;

// 16-hex-char little-endian register value -> BigInt
function leHexToBig(hex) {
    let n = 0n;
    for (let i = hex.length - 2; i >= 0; i -= 2) n = (n << 8n) | BigInt(parseInt(hex.substr(i, 2), 16));
    return n;
}
// BigInt -> 8-byte little-endian hex (GDB 'P' register write)
function bigToLeHex(n) {
    let s = "";
    for (let i = 0; i < 8; i++) { s += (Number(n & 0xFFn)).toString(16).padStart(2, "0"); n >>= 8n; }
    return s;
}
// pull register `num` (GDB hex index: "00"=x0, "20"=pc) from a T stop-reply
function reg(stop, num) {
    const m = new RegExp(num + ":([0-9a-f]{16});").exec(stop);
    return m ? leHexToBig(m[1]) : null;
}
// little-endian 4-byte instruction hex -> BRK #imm16, or -1 if not a BRK
function brkImm(instrHex) {
    if (!instrHex || instrHex.length < 8) return -1;
    const w = parseInt(instrHex.substr(0, 8).match(/../g).reverse().join(""), 16);
    if (((w & 0xFFE0001F) >>> 0) !== 0xD4200000) return -1;
    return (w >> 5) & 0xFFFF;
}
// All thread ids of the target (qfThreadInfo/qsThreadInfo). [] if unsupported.
function allThreads() {
    let ids = [], guard = 0;
    let r = send_command(`qfThreadInfo`);
    while (r && r[0] === "m" && guard++ < 128) {
        r.substr(1).split(",").forEach(x => { x = (x || "").trim(); if (/^[0-9a-f]+$/.test(x)) ids.push(x); });
        r = send_command(`qsThreadInfo`);
    }
    return ids;
}
// Read register `regHex` (e.g. "20"=pc, "00"=x0) of an arbitrary thread. null if unavailable.
function threadReg(tid, regHex) {
    send_command(`Hg${tid}`);
    const r = send_command(`p${regHex}`);
    if (!r || r.length < 16 || r[0] === "E") return null;
    return leHexToBig(r.substr(0, 16));
}
// Service a brk #0x69 sitting on `tid` (pc points at the brk; size is its x0). Steps the
// thread over the brk and returns an RX region address in x0. true if mapped, false if not.
function serviceBrk(tid, pc, size) {
    send_command(`P20=${bigToLeHex(pc + 4n)};thread:${tid};`);   // step over the brk
    if (size === null || size === 0n) {
        log(`[rl-jit] brk#0x69 size=0 (anomalous) — returning 0`);
        send_command(`P0=${bigToLeHex(0n)};thread:${tid};`);
        return false;
    }
    const rx = send_command(`_M${size.toString(16)},rx`);
    if (!rx || rx.length === 0 || rx[0] === "E") {
        log(`[rl-jit] _M alloc FAILED size=0x${size.toString(16)}: ${rx}`);
        send_command(`P0=${bigToLeHex(0n)};thread:${tid};`);
        return false;
    }
    const addr = BigInt(`0x${rx}`);
    const pr = prepare_memory_region(Number(addr), Number(size));
    send_command(`P0=${bigToLeHex(addr)};thread:${tid};`);       // return RX addr in x0
    served++;
    log(`[rl-jit] #${served} brk#0x69 size=0x${size.toString(16)} -> RX 0x${addr.toString(16)} (prepare=${pr}) tid=${tid}`);
    return true;
}

log(`[rl-jit] attaching to pid ${pid}`);
send_command(`vAttach;${pid.toString(16)}`);
log(`[rl-jit] attached (UPDATE 18: WebKit same-session robust); awaiting brk #0x69 …`);

while (true) {
    const stop = send_command(`c`);
    if (!stop || stop.length === 0) continue;
    const k = stop[0];
    if (k === "W" || k === "X") {
        log(`[rl-jit] target ended (${stop}); served ${served}, fwd ${forwarded}`);
        break;
    }
    if (k !== "T") { log(`[rl-jit] unexpected stop: ${stop}`); continue; }

    const tidM = /thread:([0-9a-f]+);/.exec(stop);
    const pc = reg(stop, "20");
    const sigM = /^T([0-9a-f]{2})/.exec(stop);
    const sig = sigM ? sigM[1] : "0b";
    if (!tidM || pc === null) { log(`[rl-jit] missing tid/pc; stop=${stop.substr(0, 48)}`); continue; }
    const tid = tidM[1];
    const instr = send_command(`m${pc.toString(16)},4`);
    const imm = brkImm(instr);
    log(`[rl-jit] stop sig=${sig} tid=${tid} pc=0x${pc.toString(16)} instr=${instr} brk=${imm}`);

    // --- FAST PATH (unchanged, clean-launch-proven): stopping thread is at brk #0x69 ----
    if (imm === 0x69) {
        serviceBrk(tid, pc, reg(stop, "00"));
        send_command(`D`);                                       // Amethyst-parity detach
        log(`[rl-jit] detached after reservation; served=${served}`);
        break;
    }

    // --- WEBKIT SAME-SESSION PATH (never hit on a clean launch) -------------------------
    // The stop was reported on a different thread while jvm-main sits at the brk. Scan
    // every thread for the brk #0x69 and service it, instead of forwarding it as a signal.
    const ids = allThreads();
    log(`[rl-jit] non-brk stop on tid ${tid}; scanning ${ids.length} threads for brk#0x69`);
    let done = false;
    for (const t of ids) {
        const tpc = threadReg(t, "20");
        if (tpc === null) continue;
        const tins = send_command(`m${tpc.toString(16)},4`);
        if (brkImm(tins) === 0x69) {
            log(`[rl-jit] brk#0x69 found on thread ${t} pc=0x${tpc.toString(16)} (stop was tid ${tid})`);
            serviceBrk(t, tpc, threadReg(t, "00"));
            send_command(`D`);
            log(`[rl-jit] detached after reservation (via thread scan); served=${served}`);
            done = true;
            break;
        }
    }
    if (done) break;

    // No brk #0x69 on any thread — forward to the VM's own handler (original behaviour).
    forwarded++;
    log(`[rl-jit] forward pc=0x${pc.toString(16)} instr=${instr} brk=${imm} sig=${sig} tid=${tid}`);
    send_command(`vCont;C${sig}:${tid}`);
}
