# rlhd java-overlay

Tracked Java source overrides layered over the **gitignored, pristine** `rlhd-src/` tree at compile time by
`stage-rlhd-zone-jar.sh` (mirrors how `shader-overlay/` overrides GLSL resources). Each file here replaces the
same-path file under `rlhd-src/src/main/java/` for the Zone-jar build, so our fixes are committed and
reproducible while `rlhd-src` stays untouched and re-fetchable.

Contents:
- `rs117/hd/renderer/zone/StaticAlphaSortingJob.java` — convert the camera yaw/pitch from JAU14
  (`getCameraYaw()/getCameraPitch()`, post rev239) to JAU11 (`>> 3 & 2047`) before indexing the 2048-entry
  `SINE`/`COSINE` tables. Without it a camera drag past angle 2047 throws `ArrayIndexOutOfBoundsException` in
  `preSceneDraw` (and below 2047 it silently sorted alpha with an 8x-too-large angle).
