# PLAN — `gitignore`: a dependency-free, spec-compliant gitignore parser and pattern matcher for Nim

## Goal

A Nim library (std lib only, `nim >= 2.2.10`) that parses `.gitignore` files and matches
paths against them with behavior identical to git itself. "Spec-compliant" means:

1. Conforms to the official documentation: https://git-scm.com/docs/gitignore
2. Where the doc is ambiguous or silent, matches git's actual implementation
   (`wildmatch.c` and `dir.c` in the git source tree) as observed via `git check-ignore`.
3. Validated against git's own test tables (`t/t3070-wildmatch.sh`, `t/t0008-ignores.sh`)
   and by differential/fuzz testing against a real `git` binary.

Any deliberate deviation from git behavior must be documented in the README, and the
git version validated against must be pinned there.

---

## Architecture: three layers

Conflating these layers is the most common design mistake in gitignore libraries.
We keep them separate. Layers 1 and 2 are the pure core (string → string, **no I/O**).
Layer 3 is an optional module where all filesystem access lives.

### Layer 1 — Pattern (core)

Parse one pattern line into a structured form; match it against a relative path.

### Layer 2 — File (core)

Parse a whole `.gitignore` buffer into an ordered pattern list; evaluate a path
against it with last-match-wins semantics.

### Layer 3 — Repository (optional, I/O)

The full stack semantics: nested `.gitignore` files from repo root down, `.git/info/exclude`,
`core.excludesFile`, directory-walk pruning, and the "excluded parent directory means
children cannot be re-included" rule. Consumers who only need to evaluate a single
`.gitignore` never touch this module.

---

## Module layout

```
src/
  gitignore.nim              # public API: re-exports the layers below
  gitignore/
    wildmatch.nim            # Layer 1: the glob matcher (pure)
    pattern.nim              # Layer 1: line parser -> Pattern object (pure)
    ignorefile.nim           # Layer 2: file parsing + last-match-wins evaluation (pure)
    repo.nim                 # Layer 3: ignore-stack + filesystem walking (I/O)
tests/
  config.nims                # --path to src/ so imports resolve
  t_wildmatch.nim            # ported git t3070 table
  t_pattern.nim              # line-parser unit tests
  t_ignorefile.nim           # ported git t0008 scenarios + evaluation tests
  t_repo.nim                 # layer-3 stack/traversal tests (temp dirs, git-free)
  differential/
    config.nims              # --path to src/ so imports resolve
    corpus.nim               # hand-written case data (gitignore buffers + path queries)
    harness.nim              # oracle runner: compares us vs `git check-ignore` (osproc)
    fuzz.nim                 # random pattern/path generator against the oracle
```

Std-lib only for the library itself. Test-only helpers may use `std/osproc`, temp dirs,
and a system `git` — dev-time tooling does not violate the dependency-free rule.

---

## Core types and API sketch

```nim
type
  Pattern* = object
    negated*: bool           # leading !
    dirOnly*: bool           # trailing /
    anchored*: bool          # contained a non-trailing slash
    glob: string             # processed pattern text handed to wildmatch
    prefixLen: int           # git's nowildcardlen: literal prefix of glob
    original*: string        # verbatim line, for explain/-v output
    lineNo*: int

  IgnoreFile* = object
    patterns*: seq[Pattern]  # in file order
    basePath*: string        # dir the file lives in, "/" separators, "" = root

  MatchKind* = enum
    mkUndecided              # no pattern matched -> fall through to lower-priority source
    mkIgnored                # matched a plain pattern
    mkIncluded               # matched a negated (!) pattern

# Layer 1
proc parsePattern*(line: string; lineNo = 0): Option[Pattern]
  # none() for blank lines, comments, and patterns that are empty after stripping
proc matches*(p: Pattern; relPath: string; isDir: bool;
              caseInsensitive = false): bool

# Layer 2
proc parseIgnoreFile*(content: string; basePath = ""): IgnoreFile
proc match*(f: IgnoreFile; relPath: string; isDir: bool;
            caseInsensitive = false): MatchKind
proc explain*(f: IgnoreFile; relPath: string; isDir: bool;
              caseInsensitive = false): Option[Pattern]
  # which pattern decided -> `git check-ignore -v` equivalent

# Layer 3
type
  IgnoreStack* = object ...    # lazy per-directory .gitignore cache inside
  RepoMatch* = object          # the three `git check-ignore -v` columns:
    source*: string            #   ignore-file path as git prints it
    pattern*: Pattern          #   carries lineNo and original text
proc newIgnoreStack*(repoRoot: string; excludesFile = "";
                     caseInsensitive = false): IgnoreStack
proc explain*(s: var IgnoreStack; path: string; isDir: bool): Option[RepoMatch]
proc isIgnored*(s: var IgnoreStack; path: string; isDir: bool): bool
iterator walkNotIgnored*(s: var IgnoreStack; dir = ""): string
```

API invariants:

- All match inputs are paths **relative to the location of the ignore file**, using `/`
  separators, no leading `./`. The core never inspects the filesystem.
- Callers must pass `isDir` explicitly. Directory-only patterns and the parent-exclusion
  rule cannot be evaluated without it, and libraries that guess from the filesystem
  become impossible to unit-test.
- `caseInsensitive` mirrors `core.ignoreCase`. ASCII-only folding (what git's wildmatch
  does) — no Unicode case folding.

---

## Layer 1a: line parser (`pattern.nim`)

Rules, applied in this exact order:

1. Strip a trailing `\r` (git reads ignore files this way; mandatory for Windows).
2. Blank line or line starting with `#` → no pattern. `\#` escapes a literal leading hash.
3. Strip **unescaped trailing spaces only** (`foo\ ` keeps its space; trailing tabs are
   NOT stripped — spaces only).
4. Leading `!` → `negated = true`, then removed. `\!` escapes a literal leading bang.
5. Pattern empty after the above (e.g. the line was just `!`) → matches nothing.
6. Trailing `/` → `dirOnly = true`, then removed.
7. Anchoring: if a `/` remains anywhere (leading or middle — the stripped trailing one
   doesn't count), the pattern is anchored to the ignore file's directory. A leading `/`
   is only an anchor; strip it. Unanchored patterns match at any depth.
8. Keep the remainder as the glob text and record the length of its literal
   (no-wildcard) prefix — git's `simple_length`/`nowildcardlen`.

Keep `original` and `lineNo` on every pattern for the `explain` API.

Matching: unanchored patterns match the path's basename at any depth (git's
`match_basename`). Anchored patterns port git's `match_pathname`: the literal prefix
is compared and consumed first, and wildmatch runs only on the remainders. That
prefix consumption is semantic, not an optimization — it can expose a glued `**`
(e.g. `foo**/bar`) at the start of the remaining pattern, where it gains its
slash-crossing meaning (see the Milestone 4 note).

## Layer 1b: wildmatch (`wildmatch.nim`)

We implement git's `wildmatch`, NOT POSIX `fnmatch`. Implemented as a direct port of
`wildmatch.c`'s recursive `dowild()` (with its two abort codes, which keep the star
backtracking from going exponential), always with `WM_PATHNAME` in effect — not the
segment-splitting approach originally sketched here.

Exact semantics:

- `*` and `?` never match `/`.
- `**` is special in exactly three positions: leading `**/`, trailing `/**`, and infix
  `/**/`. Glued to anything else (`a**b`) it degrades to two ordinary `*`s.
- Infix `/**/` must also match **zero** directories: `a/**/b` matches `a/b`.
- Bracket expressions: ranges (`[a-z]`), negation via `!` or `^`, `]` as first char is a
  literal, POSIX classes (`[:alnum:]` `[:alpha:]` `[:blank:]` `[:cntrl:]` `[:digit:]`
  `[:graph:]` `[:lower:]` `[:print:]` `[:punct:]` `[:space:]` `[:upper:]` `[:xdigit:]`).
  An unterminated `[` or malformed `[:class:]` makes the whole pattern match nothing
  (git's t3070 table demands this, despite "unterminated `[` is a literal" being the
  commonly repeated claim — see the Milestone 1 note). Brackets never match `/`.
- `\x` escapes any char `x` to a literal.
- `caseInsensitive` flag threaded through everything (ASCII folding only).

## Layer 2: evaluation (`ignorefile.nim`)

- Scan patterns **last to first**; first hit decides:
  negated → `mkIncluded`, plain → `mkIgnored`, none → `mkUndecided`.
- Unanchored-pattern/ancestor semantics: a path is ignored if a pattern matches the path
  itself **or any ancestor directory** of it (evaluated as a directory). Implement
  evaluation as "walk down the path components, checking each prefix" — both this rule
  and the "cannot re-include inside an excluded directory" rule fall out of that single
  mechanism instead of two hacks. Once a prefix directory is decided ignored, deeper
  negations are dead.
- `dirOnly` patterns only match when the candidate (or the prefix being tested) is a
  directory.

## Layer 3: repository stack (`repo.nim`)

Precedence, lowest to highest:

1. the excludesFile (git's `core.excludesFile`)
2. `.git/info/exclude`
3. `.gitignore` files from repo root down to the candidate's own directory — deeper wins.

Cross-file semantics mirror git's `prep_exclude`: evaluation walks the candidate's
directory prefixes shallowest-first, testing each prefix against every source loaded
so far. A prefix decided ignored by a *plain* pattern from ANY source is sticky across
all sources — deeper `.gitignore` files inside an ignored directory are never even
loaded, so they cannot re-include anything. A *negated* prefix decision is not sticky.
Per-directory `.gitignore` files are lazy-loaded and cached.

Config policy: the library stays dependency-free and neither parses gitconfig nor
shells out to git. `.git/info/exclude` is read automatically when present. The
excludesFile is an **opt-in constructor parameter with no default** — a library must
not silently read a global user file. git's own default is `core.excludesFile`,
falling back to `$XDG_CONFIG_HOME/git/ignore` (i.e. `~/.config/git/ignore`); callers
who want git's behavior resolve that themselves and pass the path in.
`caseInsensitive` is likewise a constructor parameter (mirrors `core.ignoreCase`).

Path handling: the API accepts OS paths (absolute under the repo root, or
root-relative with either separator), normalizes to `/`-separated root-relative form,
and re-bases each `IgnoreFile`'s queries to that file's own directory via `basePath`.
Both `info/exclude` and the excludesFile evaluate with `basePath` = repo root.

Also provides `walkNotIgnored`, a directory walker that prunes ignored directories
(never descends into them — required for both correctness and performance) and always
skips `.git`. Note: tracked files are never "ignored" by git; we do not read the
index, so this library implements `--no-index` semantics. Symlinks get git's lstat
view: a symlink is a file even when it points at a directory, and is never followed.

---

## Testing strategy

Three tiers, all run locally via nimble tasks (no CI): `nimble test` (Tier 1,
hermetic), `nimble differential` (Tier 2, needs a system git), and
`nimble fuzz` (Tier 3, optional and long-running). Tier 2's differential
harness gets built EARLY (milestone 4), not last; Tier 3's fuzzer reuses its
oracle plumbing.

### Tier 1 — Ported git test tables (`nimble test`, gating)

- `t/t3070-wildmatch.sh` is essentially a flat `(pattern, input, expected)` table.
  Mechanically translate it into `tests/t_wildmatch.nim`.
- Scenarios from `t/t0008-ignores.sh` → `tests/t_ignorefile.nim`.

### Tier 2 — Differential oracle (`nimble differential`, gating, needs system git)

`tests/differential/harness.nim` (run via `nimble differential`; kept out of
`nimble test` because it needs a system git): create a temp git repo, write a
`.gitignore` byte-exact, materialize the queried paths, run
`git check-ignore -v --non-matching --no-index --stdin` on batches of paths via
`std/osproc`, and compare against both `match` and `explain` (pattern text + lineNo
vs the `-v` columns). The hand-written corpora live in `tests/differential/corpus.nim`
and cover: escapes, trailing spaces, CRLF, `**` placements, brackets/classes,
negation chains, dir-only + negation interplay, anchoring, ancestors/dead negation,
and undecided fall-through.

### Tier 3 — Fuzzing (`nimble fuzz`, optional, long-running)

`tests/differential/fuzz.nim`: random patterns from a small alphabet
(`a b * ? [ ] ! / \ - # space **`) × random paths, thousands per run, logged seed for
reproducibility (`nimble fuzz [iterations] [seed]`, `--only:<case>`, or the
FUZZ_ITERATIONS / FUZZ_SEED env vars). This is how the quirks no documentation
mentions get found.

The project is verified locally with these three nimble tasks — there is no CI.
Only Windows/NTFS has been exercised so far; running the same tasks on
Linux/macOS would shake out path-separator and case-sensitivity assumptions.

---

## Milestones (build order)

1. ✅ **wildmatch** (DONE): `wildmatch.nim` + ported t3070 table. Pure, no I/O; most iteration
   happens here. Done when the full table passes.
   Note: git's t3070 table shows that an unterminated `[` (and a trailing lone `\`)
   makes the whole pattern match nothing, rather than being treated as a literal —
   the implementation follows git's table.
2. ✅ **line parser** (DONE): `pattern.nim` + unit tests (trailing spaces, escapes, CRLF,
   empty patterns, anchoring detection). Verified against `git check-ignore -v --no-index`.
   Note: git keeps a bare `!` line as an empty negated pattern, which can only ever match
   an empty basename (a path handed to check-ignore with a trailing slash). Our API never
   produces empty basenames, so `parsePattern` returns `none` for it — behaviorally
   identical for all valid inputs.
3. ✅ **file evaluation** (DONE): `ignorefile.nim`, last-match-wins + ancestor-prefix
   walking + ported t0008 cases (single-file subset; nested-file, exclude-file, and
   index scenarios deferred to Milestone 5). `explain` API included.
   Notes from verifying against `git check-ignore -v --non-matching --no-index`:
   - The ancestor-prefix walk must stop at the **shallowest ignored prefix** and only
     a *plain* (non-negated) prefix decision is sticky. A prefix re-included by a
     negation does not protect deeper paths: with `*` then `!foo`, git includes `foo`
     but still ignores `foo/bar` via `*`. PLAN.md's "walk the prefixes" mechanism holds,
     with that refinement.
   - `explain` for a path inside an ignored directory reports the **ancestor's**
     deciding pattern (e.g. `.gitignore:1:build/` for `build/sub/x`), matching git.
   - No behavioral deviations from git were found.
4. ✅ **differential harness** (DONE): `tests/differential/harness.nim` + `corpus.nim`
   (31 hand-written cases, 171 queries), run via `nimble differential` (needs a system
   git; `nimble test` still runs only the three pure suites). The harness creates a
   temp repo with `core.autocrlf false` / `core.ignorecase false`, writes each case's
   `.gitignore` byte-exact, materializes the queried paths (NTFS-impossible paths are
   queried as nonexistent files), batches the paths through
   `git check-ignore -v --non-matching --no-index --stdin`, and compares git's verdict
   against both `match` and `explain` (pattern text + lineNo).
   Divergence found and fixed (Layer 1a, `pattern.matches`): anchored patterns must
   port git's `match_pathname`, which compares and consumes the pattern's literal
   (no-wildcard) prefix before running wildmatch. That prefix consumption is semantic:
   it can expose a glued `**` at the start of the remaining pattern, where it gains
   its slash-crossing meaning. git matches `foo**/bar` against `foobar`, `foox/bar`,
   and `foo/x/y/bar`; wildmatch over the whole strings (our old behavior) treats
   `foo**` as two ordinary stars and matches none of the multi-segment ones.
   Regression tests added to `t_pattern.nim` and `t_ignorefile.nim` (the old
   "`**` not confused by matching leading prefix" expectation was wrong and was
   corrected to git's behavior). Zero divergences remain; no deliberate deviations.
   Validated against git 2.37.1.windows.1 on Windows/NTFS.
5. ✅ **repository layer** (DONE): `repo.nim` — `IgnoreStack` with the full source
   precedence (excludesFile < `.git/info/exclude` < root-to-leaf `.gitignore` files,
   deeper wins), lazy per-directory `.gitignore` cache, repo-level `explain` returning
   the deciding pattern plus its source file (the three `git check-ignore -v` columns),
   and the pruning `walkNotIgnored` walker (never descends into ignored directories,
   always skips `.git`). `caseInsensitive` threaded through everything.
   - Design decision (documented above in the Layer 3 section): the excludesFile is an
     opt-in constructor parameter with no default. The library does not parse gitconfig
     or shell out to git, so it cannot resolve `core.excludesFile` itself, and a library
     must not silently read a global user file (`~/.config/git/ignore`); callers who
     want git's default resolve it and pass the path in. `.git/info/exclude` *is* read
     automatically — it is repo-local state, not user config.
   - Cross-file stickiness confirmed against git (mirrors `prep_exclude`): a directory
     ignored by a plain pattern from ANY source (even `info/exclude` or the
     excludesFile) makes deeper `.gitignore` files invisible; a negated prefix decision
     is not sticky and the walk continues deeper.
   - Tests: `tests/t_repo.nim` (temp dirs, git-free, so `nimble test` stays hermetic)
     ports the t0008 scenarios M3 deferred: nested `.gitignore` precedence,
     sub-directory local (anchored) ignore, `info/exclude`, and
     info/exclude-trumps-excludesFile. Index/tracked-file and symlink/submodule
     scenarios remain out of scope (`--no-index` semantics). Walker coverage: pruning,
     `.git` skipping, and re-included directories being descended.
   - Differential: the Tier-2 harness/corpus now support ignore files in
     subdirectories, `.git/info/exclude`, and a `core.excludesfile` (passed to git via
     `-c`), and verify the repo layer for **every** case — verdict plus all three `-v`
     columns (source file, lineNo, pattern text) against repo-level `explain`
     (single-file cases still check Layer 2 directly as well). 40 cases / 229 queries,
     zero divergences against git 2.37.1.windows.1; no divergences were found in any
     layer while building M5, so no regression tests needed correcting.
6. ✅ **fuzzer + hardening** (DONE): `tests/differential/fuzz.nim` run via
   `nimble fuzz [iterations] [seed]` (also `--only:<case>`, or FUZZ_ITERATIONS /
   FUZZ_SEED env vars; the seed is logged on every run and each case is
   deterministic in (seed, case index) alone, so failures replay in isolation).
   The generator draws patterns and paths from a shared per-case token pool over
   the small alphabet (so matches are common — roughly 30% of queries match),
   emits multi-line files with negation chains, subdirectory `.gitignore` files,
   `.git/info/exclude` and an excludesFile, and keeps the oracle trustworthy:
   safe-ASCII paths only (never C-quoted by check-ignore), lowercase-only (no
   case collisions), NTFS-impossible paths queried as nonexistent files and
   never created, fixture bytes written with `writeFile`, and — a subtlety the
   fuzzer itself surfaced — a virtual path's Win32 alias (trailing spaces/dots
   stripped per component) is banned from ever being materialized, since lstat
   of `bb ` can resolve to an existing `bb`. All oracle plumbing (runGit's
   readData drain, parseGitLine's known-source parsing, resetWorktree,
   runCase's three-column comparison) is reused from `harness.nim`.
   Fuzz volume: two 3000-case runs (seeds 20260713 and 987654321), ~66,000
   queries each (~132,000 total, ~20,000 git-matched per run), zero divergences
   at completion. One real divergence was found and fixed, in **Layer 3
   (repo.nim)**: on Windows, probing `ba./.gitignore` on disk resolves via
   Win32 trailing space/dot stripping to the existing `ba/.gitignore`, so the
   stack loaded a phantom ignore file for a directory that cannot exist under
   that name and ignored `ba./b` where git reports no match. Fixed by treating
   any prefix directory whose name Win32 would rewrite as having no ignore
   file; regression test added to `t_repo.nim` and a distilled case to
   `corpus.nim` (now 41 cases / 233 queries). git won the disagreement, as
   always. README.md written: three-layer API with examples, `--no-index`
   semantics, excludesFile opt-in policy, the single deliberate deviation
   (`parsePattern` drops never-matching patterns git keeps — bare `!`, `/`,
   `//`), the pinned git version (2.37.1.windows.1), and the local
   verification workflow (`nimble test` / `differential` / `fuzz` — no CI).

---

## Non-goals

- Reading the git index (tracked-file exemption) — we implement `--no-index` semantics.
- Unicode case folding (git doesn't do it either).
- Any runtime dependency beyond the Nim standard library.
