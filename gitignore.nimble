# Package
version       = "0.1.0"
author        = "Leon Lysak (Niminem)"
description   = "dependency-free, spec-compliant gitignore parser and pattern matcher"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.4"

# Tasks
task differential, "Run the Tier-2 differential harness against the system git":
  # Needs a `git` on PATH, so it is not part of `nimble test`.
  exec "nim r --hints:off tests/differential/harness.nim"

task fuzz, "Run the Tier-3 differential fuzzer (optional, long-running)":
  # Needs a `git` on PATH; kept out of `nimble test` and `nimble
  # differential`. Usage: `nimble fuzz [iterations] [seed]` (also
  # accepts --iterations:N --seed:N --only:CASE, or the FUZZ_ITERATIONS
  # / FUZZ_SEED environment variables). The seed is logged every run.
  var args = ""
  for i in 2 ..< paramCount() + 1:
    # nimble's own args end at the task name; everything after is ours.
    if paramStr(i) == "fuzz":
      for j in i + 1 ..< paramCount() + 1:
        args.add " " & paramStr(j)
      break
  exec "nim r --hints:off tests/differential/fuzz.nim" & args
