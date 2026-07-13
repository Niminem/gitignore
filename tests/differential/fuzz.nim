## Random differential fuzzer (Tier 3, PLAN.md Milestone 6).
##
## Generates random ignore files and query paths from a small alphabet
## (`a b * ? [ ] ! / \ - # space **` plus short {a,b} literals) and runs
## them through the exact same oracle plumbing as the Tier-2 harness
## (`harness.runCase`: reset temp repo, write fixture bytes with
## writeFile, materialize creatable paths, batch everything through
## `git check-ignore -v --non-matching --no-index --stdin`, compare the
## verdict and all three `-v` columns against the repo layer — and
## against Layer 2 directly for single-file cases).
##
## Reproducibility: the master seed is logged on every run and settable
## via CLI (`fuzz [iterations] [seed]`, or `--iterations:N --seed:N`) or
## environment (FUZZ_ITERATIONS / FUZZ_SEED). Each case derives its own
## RNG state from (seed, case index) only, so a failure replays with the
## same seed regardless of iteration count — or in isolation with
## `--only:<case index>`. On divergence the harness prints the full
## repro: ignore-file bytes escaped, path, isDir, and the case name,
## which carries seed and case index.
##
## Generator constraints that keep the oracle trustworthy:
##
## - Query paths use safe ASCII only — no tabs, colons, quotes, or
##   backslashes — so `git check-ignore` never C-quotes them and the
##   output stays parseable (same discipline as corpus.nim).
## - NTFS-impossible paths (trailing space/dot, leading space, or a glob
##   metacharacter in any component) are queried as nonexistent files
##   (isDir = false, which is what git resolves for a missing path) and
##   never created. Win32 name normalization strips trailing spaces and
##   dots, so looking up `bb ` can resolve to an existing `bb` — a
##   virtual path's stripped alias must therefore never exist on disk:
##   a virtual query whose alias already exists is dropped, and the
##   alias is banned from all later materialization (queries that would
##   create a banned path are demoted to virtual instead). With the
##   alias guaranteed absent, git sees "nonexistent" whether or not
##   normalization kicks in for a given component position. (Found by
##   an early fuzz run: git matched `*/` against virtual `bb ` when
##   another query had created the directory `bb`.)
## - All path text is lowercase, so no two paths can differ only by case.
## - Conflicting materializations are demoted instead of created: a path
##   whose prefix is an existing *file* stays nonexistent, and a path
##   that already exists keeps its on-disk kind — our isDir input always
##   equals what git resolves from the filesystem.
## - Patterns and paths draw literals from a shared per-case token pool,
##   so matches are common (they are vanishingly rare with independent
##   random text); multi-line files with negation chains, subdirectory
##   `.gitignore` files, `.git/info/exclude`, and an excludesFile are all
##   generated with tunable probabilities.

import std/[options, os, random, sets, strutils, tables, times]
import corpus
import harness

# ---------------------------------------------------------------- generator

const
  pathSpecials = ["*", "?", "[", "]", "-", " ", "#", "!"]
  ntfsBad = {'*', '?', '[', ']'}

proc genTokens(r: var Rand): seq[string] =
  ## 3-6 short literals over {a, b}, shared by patterns and paths.
  for _ in 0 ..< r.rand(3 .. 6):
    var t = newString(r.rand(1 .. 3))
    for i in 0 ..< t.len:
      t[i] = if r.rand(1.0) < 0.5: 'a' else: 'b'
    result.add t

proc genSegment(r: var Rand; tokens: seq[string]): string =
  ## One '/'-free pattern segment: 1-3 atoms, biased toward pool literals
  ## so patterns actually stand a chance of matching generated paths.
  const brackets = ["[ab]", "[!a]", "[a-b]", "[]a]", "[!]a]", "[b",
                    "[[:alpha:]]", "[[:lower:]]", "[[:bogus:]]"]
  const escapees = ["a", "b", "*", "?", "[", "]", "!", "#", " ", "-"]
  for _ in 0 ..< r.rand(1 .. 3):
    case r.rand(0 .. 11)
    of 0 .. 4: result.add r.sample(tokens)
    of 5: result.add "*"
    of 6: result.add "?"
    of 7: result.add "**"
    of 8: result.add r.sample(brackets)
    of 9: result.add "\\" & r.sample(escapees)
    else: result.add r.sample(pathSpecials)

proc genPatternLine(r: var Rand; tokens: seq[string]): string =
  let roll = r.rand(1.0)
  if roll < 0.04: return ""
  if roll < 0.08: return "# comment"
  if r.rand(1.0) < 0.28: result.add "!"
  if r.rand(1.0) < 0.18: result.add "/"
  for i in 0 ..< r.rand(1 .. 3):
    if i > 0: result.add "/"
    result.add genSegment(r, tokens)
  if r.rand(1.0) < 0.18: result.add "/"
  if r.rand(1.0) < 0.10: result.add repeat(' ', r.rand(1 .. 2))

proc genIgnoreContent(r: var Rand; tokens: seq[string]): string =
  let eol = if r.rand(1.0) < 0.12: "\r\n" else: "\n"
  let n = r.rand(1 .. 8)
  for i in 0 ..< n:
    result.add genPatternLine(r, tokens)
    if i < n - 1 or r.rand(1.0) < 0.85:
      result.add eol

proc genComponent(r: var Rand; tokens: seq[string]): string =
  for _ in 0 ..< r.rand(1 .. 2):
    if r.rand(1.0) < 0.82: result.add r.sample(tokens)
    else: result.add r.sample(pathSpecials)
  if r.rand(1.0) < 0.07:
    result.add (if r.rand(1.0) < 0.5: "." else: " ")
  for c in result:
    if c notin {' ', '.'}:
      return
  # A component of only spaces/dots would Win32-normalize to nothing at
  # all; keep every component resolvable by anchoring it with a literal.
  result = r.sample(tokens) & result

proc genPath(r: var Rand; tokens: seq[string]): string =
  const depths = [1, 1, 1, 2, 2, 2, 3, 3, 4]
  var comps: seq[string]
  for _ in 0 ..< r.sample(depths):
    comps.add genComponent(r, tokens)
  comps.join("/")

# --------------------------------------------- materialization bookkeeping

func ntfsImpossible(path: string): bool =
  ## Whether any component keeps this path off the disk. Trailing
  ## space/dot components are impossible on NTFS (and leading-space ones
  ## stay virtual too, dodging any Win32 name mangling); bracket
  ## characters are technically legal but stay virtual as well, per the
  ## corpus discipline (`*` and `?` are illegal anyway, and a uniform
  ## rule is simpler).
  for comp in path.split('/'):
    if comp.len == 0 or comp[0] == ' ' or comp[^1] in {' ', '.'}:
      return true
    for c in comp:
      if c in ntfsBad:
        return true
  false

func win32Alias(path: string): string =
  ## The most-aggressive plausible Win32 normalization of `path`:
  ## leading spaces and trailing spaces/dots stripped from every
  ## component. A virtual path's lstat can resolve to (at most) this
  ## alias, so keeping the alias off the disk keeps the virtual path
  ## reliably nonexistent no matter which components the OS normalizes.
  var comps = path.split('/')
  for c in comps.mitems:
    var lo = 0
    while lo < c.len and c[lo] == ' ': inc lo
    var hi = c.len
    while hi > lo and c[hi - 1] in {' ', '.'}: dec hi
    c = c[lo ..< hi]
  comps.join("/")

proc addParents(disk: var Table[string, bool]; path: string) =
  for i in 0 ..< path.len:
    if path[i] == '/':
      disk[path[0 ..< i]] = true

proc resolveQuery(disk: var Table[string, bool]; banned: var HashSet[string];
                  path: string; wantDir: bool): Option[Query] =
  ## Decides isDir/create so that the query's isDir always equals what
  ## git resolves from the filesystem. `disk` maps every created/implied
  ## path to its kind (true = dir); `banned` holds Win32 aliases of
  ## already-emitted virtual queries, which must never come into
  ## existence (all creations happen before git runs, so a later
  ## creation would retroactively change what git sees for the virtual
  ## path — that is why this returns `none` instead of guessing when an
  ## alias already exists).
  if ntfsImpossible(path):
    let alias = win32Alias(path)
    if alias != path and not ntfsImpossible(alias):
      if alias in disk:
        return none(Query)  # normalization could resolve it; skip
      banned.incl alias
    return some Query(path: path, isDir: false, create: false)
  if path in disk:
    return some Query(path: path, isDir: disk[path], create: false)
  var blocked = path in banned
  if not blocked:
    for i in 0 ..< path.len:
      if path[i] == '/':
        let prefix = path[0 ..< i]
        if prefix in banned or not disk.getOrDefault(prefix, true):
          # A banned prefix must stay absent; an existing-file prefix
          # makes creation impossible. Either way: query as nonexistent.
          blocked = true
          break
  if blocked:
    banned.incl path  # keep later same-path queries consistent
    return some Query(path: path, isDir: false, create: false)
  addParents(disk, path)
  disk[path] = wantDir
  some Query(path: path, isDir: wantDir, create: true)

# -------------------------------------------------------------- case maker

proc genCase(seed: int64; idx: int): Case =
  ## Deterministic in (seed, idx) alone, so any case replays in isolation.
  var caseSeed = seed *% 0x9E3779B97F4A7C15'i64 +% int64(idx)
  if caseSeed == 0: caseSeed = 1
  var r = initRand(caseSeed)
  let tokens = genTokens(r)

  var gitignore = ""
  if r.rand(1.0) < 0.92:
    gitignore = genIgnoreContent(r, tokens)

  var files: seq[tuple[path, content: string]]
  if r.rand(1.0) < 0.35:
    var dirs: seq[string]
    for _ in 0 ..< r.rand(1 .. 2):
      var comps: seq[string]
      for _ in 0 ..< r.rand(1 .. 2):
        comps.add r.sample(tokens)
      let dir = comps.join("/")
      if dir notin dirs:
        dirs.add dir
        files.add (dir & "/.gitignore", genIgnoreContent(r, tokens))
  if r.rand(1.0) < 0.20:
    files.add (".git/info/exclude", genIgnoreContent(r, tokens))
  var excludes = ""
  if r.rand(1.0) < 0.15:
    excludes = genIgnoreContent(r, tokens)

  # Seed the disk table with what the fixture files imply; they are
  # written before queries materialize, so they win every conflict.
  var disk = initTable[string, bool]()
  for (path, _) in files:
    if not path.startsWith(".git/"):
      addParents(disk, path)
      disk[path] = false

  var queries: seq[Query]
  var banned = initHashSet[string]()
  for _ in 0 ..< r.rand(15 .. 30):
    let q = resolveQuery(disk, banned, genPath(r, tokens),
                         wantDir = r.rand(1.0) < 0.3)
    if q.isSome:
      queries.add q.get

  Case(name: "fuzz seed=" & $seed & " case=" & $idx,
       gitignore: gitignore, files: files, excludesFile: excludes,
       queries: queries)

# ------------------------------------------------------------------- main

proc usageQuit() =
  quit("usage: fuzz [iterations] [seed] " &
       "[--iterations:N] [--seed:N] [--only:CASE]\n" &
       "env fallbacks: FUZZ_ITERATIONS, FUZZ_SEED")

proc optVal(a: string): string =
  let k = a.find({':', '='})
  if k < 0:
    quit("option needs a value, e.g. --seed:42 — got: " & a)
  a[k + 1 .. ^1]

when isMainModule:
  var iterations = 500
  var seed = int64(epochTime() * 1000)
  var only = -1
  if existsEnv("FUZZ_ITERATIONS"):
    iterations = parseInt(getEnv("FUZZ_ITERATIONS"))
  if existsEnv("FUZZ_SEED"):
    seed = parseBiggestInt(getEnv("FUZZ_SEED"))
  var positional: seq[string]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--iterations"): iterations = parseInt(optVal(a))
    elif a.startsWith("--seed"): seed = parseBiggestInt(optVal(a))
    elif a.startsWith("--only"): only = parseInt(optVal(a))
    elif a.startsWith("-"): usageQuit()
    else: positional.add a
  if positional.len > 2: usageQuit()
  if positional.len > 0: iterations = parseInt(positional[0])
  if positional.len > 1: seed = parseBiggestInt(positional[1])
  if seed == 0: seed = 1

  echo "fuzz: seed=", seed, " iterations=", iterations,
       (if only >= 0: " (only case " & $only & ")" else: "")

  let repoDir = setupRepo()
  let (gitVersion, _) = runGit(repoDir, ["--version"])
  let t0 = epochTime()
  var failures, queries, gitMatches = 0
  for i in 0 ..< iterations:
    if only >= 0 and i != only:
      continue
    runCase(repoDir, genCase(seed, i), failures, queries, gitMatches)
    if only < 0 and (i + 1) mod 100 == 0:
      echo "  ", i + 1, "/", iterations, " cases: ", queries, " queries, ",
           gitMatches, " matched by git, ", failures, " divergences"
  try:
    removeDir(repoDir)
  except OSError:
    discard  # a stale temp dir is not worth failing the run over

  let elapsed = formatFloat(epochTime() - t0, ffDecimal, 1)
  if failures > 0:
    echo failures, " divergence(s) across ", queries, " queries"
    echo "reproduce: nimble fuzz ", iterations, " ", seed,
         "   (or --seed:", seed, " --only:<case> for a single case)"
    quit(1)
  echo "OK: ", queries, " queries (", gitMatches,
       " matched by git) across ",
       (if only >= 0: 1 else: iterations), " cases, zero divergences (",
       gitVersion.strip, ", ", elapsed, "s, seed=", seed, ")"
