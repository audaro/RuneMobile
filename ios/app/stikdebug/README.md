# StikDebug JIT script — `runelite-jit.js`

The piece that makes the W1 shell actually boot HotSpot on the iPhone 17 Pro Max (iOS 26.5, TXM).

## Why it exists
On a TXM device the app cannot map executable (RX) memory itself; StikDebug (the attached debugger)
must do it on the JVM's behalf. Our jre21's libjvm requests code-cache memory via a single thunk:

```
char* BreakGetJITMapping(size_t bytes)   ==   brk #0x69 ; ret
```

HotSpot calls it with the requested **size in x0** and expects the address of a freshly-mapped **RX
region back in x0**. StikDebug's stock `universal.js` only returns a stub (`0xE0000069`) for `brk #0x69`,
which HotSpot then tries to execute → crash (this is the crash we hit on the first device run).
`runelite-jit.js` provides a real handler: allocate an RX region of `size` (`_M …,rx`), wire it up for
TXM execution (`prepare_memory_region`), and return its address in x0. It stays attached and services
every request (the code cache grows during the run).

It uses only StikDebug's documented builtins (`get_pid`, `send_command`, `prepare_memory_region`, `log`),
the GDB remote protocol, and the AArch64 BRK encoding — no app-side native glue required.

### Why it ALSO maps on fault (not just brk #0x69)
On-device disassembly showed libjvm's brk path lives in `os::pd_reserve_memory(size, executable)` →
`get_debug_jit_mapping`, gated behind `MirrorMappedCodeCache==1 && DeviceRequiresTXMWorkaround()`. That TXM
check reads `/private/preboot/.../Ap,TrustedExecutionMonitor.img4`, which the **app sandbox can't open**, so it
returns 0 → libjvm falls back to `mmap(PROT_READ|PROT_EXEC)`, which on TXM is **not actually executable** →
HotSpot jumps into it and takes an instruction-abort. The first device run showed exactly this (faults at
generated-code PCs, never a `brk #0x69`). So the script handles **both**: real `brk #0x69` requests *and*
instruction-abort faults — on a fault it calls `prepare_memory_region` for the faulting 16 KB page and retries
(continue without re-delivering the signal), turning the debugger into the on-demand RX mapper.

## Install + assign (on the iPhone)
1. Get `runelite-jit.js` onto the phone and into StikDebug's scripts:
   - AirDrop the file to the iPhone, or
   - **Files → On My iPhone → StikDebug → scripts/** and drop it there, or use StikDebug's in-app
     "add/import script" button.
2. In **StikDebug**, open the app list, select **RuneMobile**, and **assign** `runelite-jit.js` as its
   script. (StikDebug stores the per-app mapping; on iOS-26 TXM it runs the assigned script on attach.)
3. Make sure **LocalDevVPN** is connected.

## Run loop
1. Launch **RuneMobile** → it waits at "JIT: waiting…".
2. **Attach StikDebug** to RuneMobile (with `runelite-jit.js` assigned). `CS_DEBUGGED` flips green; the
   script attaches and sits in its continue-loop waiting for `brk #0x69`.
3. Tap **Start JVM**. Watch RuneMobile's console and StikDebug's log:
   - StikDebug log should show `[rl-jit] #1 brk #0x69 size=… -> RX 0x…` lines (one per code-cache grow).
   - RuneMobile should reach `=== RuneMobile: HotSpot reached main() ===` and print
     `VERDICT = JIT ACTIVE`.

## If it still crashes / hangs
Capture both logs. Useful signals:
- **No `[rl-jit] attached` line** → the script wasn't assigned/run; re-check the assignment.
- **`_M alloc FAILED`** → RX allocation rejected (try a smaller `-XX:ReservedCodeCacheSize` in the app's
  JLI args, e.g. 64m).
- **`[rl-jit] non-0x69 stop …`** → HotSpot hit a different fault; paste the pc/instr line.
- **Reaches main but `VERDICT = INTERPRETER ONLY`** → JIT mapping worked for the interpreter but C1/C2
  didn't engage; we look at compiler threads next.
