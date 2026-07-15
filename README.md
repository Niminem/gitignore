# gitignore

A dependency-free, spec-compliant `.gitignore` parser and pattern matcher for Nim (std lib only).

"Spec-compliant" means: behavior identical to git itself. Where the [official documentation](https://git-scm.com/docs/gitignore) is ambiguous or silent, this library matches git's actual implementation (`wildmatch.c` and `dir.c`), as validated by ported git test tables, a differential test harness, and a randomized fuzzer — all running real queries against a real `git check-ignore` and demanding byte-identical answers.

## Installation

Install via nimble:

```
nimble install gitignore
```

or clone via git:

```
git clone https://github.com/Niminem/gitignore
```

## The three layers

Most gitignore libraries conflate parsing a pattern, evaluating a file, and
walking a repository. This library keeps them separate. Layers 1 and 2 are
pure string processing (no I/O); Layer 3 is an optional module where all
filesystem access lives.

```nim
import gitignore            # everything
import gitignore/ignorefile # layers 1 + 2 only, if you want to avoid the I/O module
```



### Layer 1 — one pattern (`gitignore/pattern`)

Parse a single gitignore line and match paths against it.

```nim
import gitignore/pattern

let p = parsePattern("doc/**/*.txt").get
assert p.matches("doc/a.txt", isDir = false)
assert p.matches("doc/sub/a.txt", isDir = false)
assert not p.matches("other/a.txt", isDir = false)

# blank lines, comments, and never-matching lines yield none:
assert parsePattern("# comment").isNone
```

`parsePattern` returns `Option[Pattern]`; the `Pattern` carries `negated`,
`dirOnly`, `anchored`, plus the verbatim `original` text and `lineNo` for
explain output. `matches` ignores negation — flipping the outcome is the next
layer's job. The underlying glob engine, `wildmatch(pattern, text)`, is a
faithful port of git's `wildmatch.c` (including its abort codes, so star
backtracking never goes exponential) and is exported too.

### Layer 2 — one ignore file (`gitignore/ignorefile`)

Parse a whole buffer; evaluate paths with git's last-match-wins and
ancestor-directory semantics.

```nim
import gitignore/ignorefile

let f = parseIgnoreFile("*.log\n!keep.log\nbuild/\n!build/kept\n")
assert f.match("debug.log", isDir = false) == mkIgnored
assert f.match("keep.log",  isDir = false) == mkIncluded   # re-included
assert f.match("readme",    isDir = false) == mkUndecided  # no pattern applies
assert f.match("build/kept", isDir = false) == mkIgnored   # dead negation:
  # nothing inside an ignored directory can be re-included

# which pattern decided? (the `git check-ignore -v` columns)
let why = f.explain("debug.log", isDir = false)
assert why.get.lineNo == 1 and why.get.original == "*.log"
```

All match inputs are `/`-separated paths relative to the ignore file's
directory, with no leading `./`. `isDir` is always explicit — directory-only
patterns and the parent-exclusion rule cannot be evaluated without it, and the
core never touches the filesystem to guess.

### Layer 3 — a repository (`gitignore/repo`)

The full stack: nested `.gitignore` files from the repo root down,
`.git/info/exclude`, an optional excludes file, cross-file stickiness
(a directory ignored by a plain pattern hides deeper `.gitignore` files
entirely), and a pruning directory walker.

```nim
import gitignore/repo

var stack = newIgnoreStack("path/to/repo")
assert stack.isIgnored("build/artifact.o", isDir = false)

# repo-level explain: the three `git check-ignore -v` columns
let m = stack.explain("vendor/lib.js", isDir = false)
if m.isSome:
  echo m.get.source, ":", m.get.pattern.lineNo, ":", m.get.pattern.original

# walk everything that is not ignored (prunes ignored dirs, skips .git)
for path in stack.walkNotIgnored():
  echo path
```

Accepted paths: absolute under the repo root, or root-relative, with either
separator. `caseInsensitive` (mirroring `core.ignoreCase`) is a constructor
parameter on the stack and a per-call parameter in the pure layers.

## Semantics and policy

- `--no-index` **semantics.** git never ignores tracked files; this library
does not read the index, so it behaves exactly like
`git check-ignore --no-index`. Every claim of git-identical behavior is
against that mode.
- **The excludes file is opt-in.** `.git/info/exclude` is read automatically —
it is repo-local state. But the library neither parses gitconfig nor shells
out to git, so it cannot resolve `core.excludesFile`, and a library must not
silently read a global user file. Callers who want git's default behavior
resolve it themselves (`core.excludesFile`, falling back to
`$XDG_CONFIG_HOME/git/ignore`, i.e. `~/.config/git/ignore`) and pass the
path to `newIgnoreStack(root, excludesFile = ...)`.
- **Symlinks** get git's lstat view: a symlink is a file even when it points
at a directory, and is never followed.
- **Case folding** is ASCII-only, like git's own `WM_CASEFOLD`.



## Deliberate deviations from git

Exactly one, and it is unobservable through this API: git keeps patterns that
can never match anything — a bare `!` line, or a `/` or `//` line optionally
preceded by `!` — as inert entries in its pattern list, while `parsePattern`
returns `none` for them. (A bare `!` in git can only ever match an empty
basename, which requires handing check-ignore a path with a trailing slash;
this API never produces empty basenames.) Behavior is identical for all valid
inputs.

## Verification

Everything runs locally via nimble tasks.


| task                  | what it does                                                                                                                                                                                                                                | needs git? |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `nimble test`         | hermetic unit suites: the ported `t3070-wildmatch` table, line-parser tests, `t0008-ignores` scenarios, repo-stack tests                                                                                                                    | no         |
| `nimble differential` | Tier-2 oracle: hand-written corpus (41 cases / 233 queries) run through a real `git check-ignore -v --non-matching --no-index` in a temp repo, comparing the verdict and all three `-v` columns                                             | yes        |
| `nimble fuzz`         | Tier-3 fuzzer (optional, long-running): random ignore files and paths through the same oracle. Seed is logged every run; reproduce with `nimble fuzz <iterations> <seed>` (also `--only:<case>`, or `FUZZ_ITERATIONS`/`FUZZ_SEED` env vars) | yes        |


`nimble fuzz` defaults to 500 random cases (roughly 11,000 queries). Every
divergence it has ever found was resolved in git's favor, with a regression
test added to the unit suites and a distilled case added to the differential
corpus.