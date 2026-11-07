# Simulator gate

One command that builds the iOS app for the Simulator, runs every simulator check against that build, and gives
one verdict.

```sh
ios/dev-tools/sim-gate.sh                        # build + install, then every check
ios/dev-tools/sim-gate.sh --jars                 # restage the jars first: use this after a Java change
ios/dev-tools/sim-gate.sh --no-build             # reinstall the last simulator build instead of building
ios/dev-tools/sim-gate.sh --skip sweep           # leave checks out: census, screens, sweep, renderers (comma list)
RENDERERS="gpu 117hd" ios/dev-tools/sim-gate.sh  # boot only these renderers (default cpu gpu 117hd)
```

It ends with `VERDICT: SIM_GATE_GREEN` (exit 0) or `_RED` (exit 1). With a current build it takes about seventeen
minutes, six or seven of them the plugin sweep and about seven the heat check (`--skip sweep` leaves it out). A check that fails doesn't stop the run, so one run shows everything that is wrong; only a failed build
or install stops it early.

## The checks

1. **build**: `../run-sim.sh --no-launch` builds and installs the Debug simulator app.
2. **census**: `../bridge-census/run-census-sim.sh`. Every JNI lookup in the native source resolves in the app's
   VM (`IOS_BRIDGE_CENSUS_GREEN`).
3. **screens**: `../sim-screens/sim-screens.py`. The native screens match their goldens (`SIM_SCREENS_GREEN`).
   The Simulator window must be in landscape, and the goldens must exist on this Mac (`--update` writes them).
4. **sweep**: `../sim-screens/plugin-sweep.py`. Every plugin's settings screen and every side panel on the rail
   opens, isn't blank, and logs no `[bridge-fault]` or `[json-fault]` (`PLUGIN_SWEEP_GREEN`). No goldens: it checks
   what each screen reports it shows, and the screenshot.
5. **renderer cpu / gpu / 117hd**: `boot-renderer.py` launches the app on each renderer and passes when the client
   reaches `LOGIN_SCREEN` on the renderer it was asked for and is still running 15 s later (`DWELL=` changes
   that). "The renderer it was asked for" means the shell logged `renderer pref = <renderer>`, not the crash
   cookie's CPU fallback, and then its own survival proof: the GPU and 117HD plugins force-disabled for CPU,
   `GPU first frame` for GPU, `117HD first GL present` for 117HD. A crash cookie left by an earlier GPU launch
   that was killed before its first frame is removed first, and the step says so.
6. **heat**: `../diagnostics/sim-heat-check.py`, skipped with the renderers. The driver's `heat` command stands in
   for the phone's thermal state and Low Power Mode, and each renderer has to show the limit in its Share logs
   report and fall under it (`SIM_HEAT_GREEN`). A renderer that doesn't run faster than the limits fails, because
   the check would prove nothing. On 117 HD it also moves the resolution setting as a player would, before and during
   a throttle, and the player's value has to be the one that comes back, then kills the app with a throttle saved and
   the next launch has to save the player's value before it drops the marker. Then a launch with no saved renderer has
   to pick base GPU. About eight minutes in all.
7. **log scan**: `tools/log-scan/log-scan.py` over the `jvm-stdio.log` and `hello-shell.log` of every launch
   above. It fails on any line that isn't on the known-noise list (`tools/log-scan/known-noise.json`), on any
   shader error (the noise list can't excuse those), and when a launch that passed left no logs of its own.

Every launch is logged out (`-RMSkipLogin`), so the gate never logs into the game, even when the simulator holds a
session from `run-sim.sh --desktop-login`. The app is terminated at the end.

## Output

`build/sim-gate/<stamp>/`:

- `summary.txt`: one line per check;
- `build.log`, `census.log`, `screens.log`, `sweep.log`, `renderer-<r>.log`, `log-scan.log`: each step's output;
- `logs/<launch>/jvm-stdio.log` and `hello-shell.log`: each launch's logs, copied before the next launch rotates
  them away;
- `log-scan.json`: the scan's full result, with every new signature and the shader errors per file.

## When it goes RED

- **census** or **screens**: read the step's log. Screens keeps its shots and diff heatmaps where `screens.log`
  says. Changed a screen on purpose? Check the shots, then `sim-screens.py --update`.
- **sweep**: `sweep.log` has a line per screen with what failed; the shots, `summary.json` and a `results.md`
  table are in the folder its `shots=` line names. Re-run only the failing screens by name
  (`plugin-sweep.py --no-build "config:<plugin>" "panel:<tooltip>"`).
- **renderer**: `renderer-<r>.log` says what was missing, and `logs/renderer-<r>/` has that launch's logs.
- **log scan**: `log-scan.log` lists the new lines by what logged them, first one first. A real problem: fix it.
  A line that is expected: add an entry to `known-noise.json` with a narrow regex and the reason it is expected
  (`log-scan.py --suggest` prints a stub). Don't add a shader error; fix the shader.

## What it does not check

What the simulator can't show: performance, the StikDebug JIT path, the phone's GPU driver (GPU modes draw with
Apple's software renderer here), touch, and backgrounding. Gameplay: every launch stops at the login screen.
