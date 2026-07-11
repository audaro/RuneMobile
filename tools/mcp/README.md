# harness MCP server

A small stdio [MCP](https://modelcontextprotocol.io) server that exposes the
project's dev-tools harnesses as callable tools, so the desktop render / QA loop
can be driven directly instead of by hand. Zero third-party dependencies — pure
Python stdlib for the protocol, plus PIL + numpy (only for `image_diff`).

## Why `/usr/bin/python3`

The server is pinned to the macOS system Python because that is the interpreter
that ships PIL (11.x) + numpy on this machine — Homebrew's `python3` does not have
them. `image_diff` needs both; everything else is stdlib. If you move machines,
point `.mcp.json` at whatever `python3` has `PIL` + `numpy`
(`python3 -c "import PIL, numpy"` must succeed) and fix the absolute script path.

## Registration

Register it for the project by creating `.mcp.json` at the repo root (gitignored — it holds a
machine-specific absolute path, so each clone writes its own):

```json
{
  "mcpServers": {
    "harness": {
      "command": "/usr/bin/python3",
      "args": ["/path/to/repo/tools/mcp/harness_server.py"]
    }
  }
}
```

The MCP client prompts once to trust a project-scoped server. It is picked up at
session start, so after first adding it, start a fresh session (or re-trust) for
the tools to appear.

## Tools

| tool | needs a device? | what it does |
|------|-----------------|--------------|
| `headless_render` | no (desktop JVM) | run the headless capture (`run-headless*.sh`); returns PNG paths + `nullGraphics`/`gameState` markers. `mode=in_game` needs `tokens.json`. Slow (~1-3 min). |
| `image_diff` | no | per-channel PNG diff: `maxChannelDelta`, `meanChannelDelta`, RMSE, `pctPixelsDiffering`, + an inlined red heatmap. The previously-unimplemented T12.1 golden compare. |
| `jvm_bench` | no | compile (`--release 8`) + run `jvmbench/Bench.java`; parsed ops/s for floatbits/raster/mixed. |
| `glsl_es_validate` | no (needs `glslangValidator`) | run `glsl_es_repro.py`; per-mode GLES 3.00 OK/FAIL. |
| `list_evidence` | no | index `evidence/` + headless `out*/` PNG catalogs into JSON, newest-first. |
| `android_screenshot` | yes | `adb exec-out screencap` → PNG. |
| `android_set_hd_config` | yes | live 117HD preset flip (`SET_HD_CONFIG` broadcast) — the FIX-13 A/B knob. |
| `android_fps` | yes | run `fps-measure.sh` for N seconds; mean/median/min/max fps. |
| `run_verdict` | no | run any in-repo `*-verdict.sh` against a log; returns GREEN/RED/PASS/FAIL. |

### Typical loops

- **Desktop-vs-port render A/B** — `headless_render` (ground truth) → `image_diff`
  against a device/emulator screenshot (crop to a common region if dims differ).
- **117HD perf A/B** (FIX-13) — `android_fps` baseline → `android_set_hd_config`
  (e.g. scale 85, aniso 8) → `android_fps` again → compare.
- **Render-regression gate** — keep a golden PNG, `image_diff` new captures against
  it with a `threshold`, fail on `maxChannelDelta` over budget.

## Smoke test

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | /usr/bin/python3 tools/mcp/harness_server.py
```

Adding a tool is a single entry in the `TOOLS` registry (description, JSON Schema,
handler) at the bottom of `harness_server.py`.
