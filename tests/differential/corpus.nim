## Hand-written differential corpora (Tier 2, PLAN.md Milestones 4 + 5).
##
## Each case is a verbatim root `.gitignore` buffer — optionally plus
## further ignore files in subdirectories, `.git/info/exclude`, and a
## core.excludesFile (Milestone 5, repo layer) — and a list of path
## queries. No expected results are stored here: the harness runs the
## same queries through a real `git check-ignore` in a temp repo (the
## oracle) and through our library, and compares.
##
## Query kinds:
## - `f(path)`  — a regular file, created on disk so git sees isDir = false.
## - `d(path)`  — a directory, created on disk so git sees isDir = true.
## - `v(path)`  — "virtual": a path that cannot exist on NTFS (trailing
##   spaces/dots, glob metacharacters) or must not exist (case-collision
##   probes). Never created; queried with isDir = false, which is also what
##   git resolves for a nonexistent path.
##
## Corpus paths stick to safe ASCII without tabs, backslashes, quotes, or
## colons, so `git check-ignore -v` never C-quotes them and the output stays
## trivially parseable.

type
  Query* = object
    path*: string   ## `/`-separated path relative to the repo root
    isDir*: bool
    create*: bool   ## materialize on disk before asking git

  Case* = object
    name*: string
    gitignore*: string  ## root .gitignore, written byte-exact — CRLF and
                        ## trailing spaces matter ("" = no root file)
    files*: seq[tuple[path, content: string]]
      ## additional ignore files, e.g. "a/.gitignore" or
      ## ".git/info/exclude" — written byte-exact too
    excludesFile*: string
      ## content for a core.excludesFile ("" = none); the harness writes
      ## it outside the worktree and passes `-c core.excludesfile=...`
    queries*: seq[Query]

func f*(path: string): Query = Query(path: path, isDir: false, create: true)
func d*(path: string): Query = Query(path: path, isDir: true, create: true)
func v*(path: string): Query = Query(path: path, isDir: false, create: false)

const corpusCases* = [
  # ------------------------------------------------------------- escapes
  Case(name: "escapes: leading hash and bang",
    gitignore: "\\#hash\n\\!bang\n!!neg\n",
    queries: @[f"#hash", f"!bang", f"!neg", f"hash", f"bang"]),

  Case(name: "escapes: glob metacharacters",
    gitignore: "\\*star\n\\?q\n\\[br\nl\\it\n",
    queries: @[v"*star", f"star", f"xstar", v"?q", f"aq",
               f"[br", f"bbr", f"lit", f"lxit"]),

  # ------------------------------------------------------ trailing spaces
  Case(name: "trailing spaces: escaped and not",
    gitignore: "trail   \nesc\\ \nmix\\  \nlone\\\n",
    queries: @[f"trail", v"trail ", v"esc ", f"esc",
               v"mix ", v"mix  ", f"lone"]),

  Case(name: "trailing dot path (NTFS-impossible)",
    gitignore: "dot.\n",
    queries: @[v"dot.", f"dot"]),

  # ----------------------------------------------------------------- CRLF
  Case(name: "CRLF ignore file",
    gitignore: "afoo\r\n# c\r\n\r\nbbar\r\n!afoo\r\ncrsp \r\n",
    queries: @[f"afoo", f"bbar", f"neither", f"crsp", v"crsp "]),

  Case(name: "mixed line endings, no final newline",
    gitignore: "mix1\nmix2\r\nmix3",
    queries: @[f"mix1", f"mix2", f"mix3", f"mix4"]),

  # -------------------------------------------------------- ** placements
  Case(name: "** leading",
    gitignore: "**/foo\n**/bar/baz\n",
    queries: @[f"foo", f"a/foo", f"a/b/foo", f"afoo",
               f"bar/baz", f"x/bar/baz", f"x/baz"]),

  Case(name: "** trailing",
    gitignore: "abc/**\n",
    queries: @[d"abc", f"abc/x", f"abc/d/y", f"abcx"]),

  Case(name: "** infix matches zero or more directories",
    gitignore: "a/**/b\n",
    queries: @[f"a/b", f"a/x/b", f"a/x/y/b", f"a/xb", f"ab"]),

  Case(name: "** glued degrades to two ordinary stars",
    gitignore: "a**b\nfoo**/bar\n**tail\nhead**\n",
    queries: @[f"ab", f"azb", f"sub/aqb", f"a/b",
               f"foo/bar", f"foox/bar", f"foo/x/bar",
               f"tail", f"xtail", f"s/ytail", f"tailx",
               f"head", f"headq"]),

  Case(name: "** trailing with dirOnly",
    gitignore: "abc2/**/\n",
    queries: @[d"abc2", d"abc2/d", f"abc2/f", f"abc2/d/x"]),

  Case(name: "literal prefix exposes ** (match_pathname semantics)",
    gitignore: "/lit**\nsub/x**y\nw/x**/b\n",
    queries: @[f"lit", f"litx", f"litq/y", f"litr/y/z", f"other",
               f"sub/xzy", f"sub/xz/y",
               f"w/x/b", f"w/xq/b", f"w/x/q/b", f"w/y/b"]),

  Case(name: "** with leading slash anchor",
    gitignore: "/**/lsfoo\n/lx/**\n",
    queries: @[f"lsfoo", f"a/lsfoo", f"a/b/lsfoo", f"lx/y", f"q/lx/y"]),

  # ------------------------------------------------- brackets and classes
  Case(name: "brackets: sets, ranges, negation, literal ]",
    gitignore: "[a-c]x\n[!d]y\n[]e]z\n[f-]w\n",
    queries: @[f"ax", f"bx", f"cx", f"dx", f"cy", f"dy",
               f"]z", f"ez", f"az", f"fw", f"-w", f"gw"]),

  Case(name: "brackets: escaped range char and negated literal ]",
    gitignore: "[a\\-c]x\n[!]f]y\n",
    queries: @[f"ax", f"-x", f"cx", f"bx", f"gy", f"fy", f"]y"]),

  Case(name: "POSIX classes",
    gitignore: "[[:digit:]]d\n[[:upper:]]u\n[[:punct:]]p\n",
    queries: @[f"1d", f"dd", f"Au", v"au", f"-p", f"1p"]),

  Case(name: "malformed brackets and classes match nothing",
    gitignore: "foo[\na[b\n[[:bogus:]]bar\nback\\\n",
    queries: @[f"foo[", f"fooa", f"a[b", f"xbar", f"bar", f"back"]),

  # ------------------------------------------------------ negation chains
  Case(name: "negation chain, last match wins",
    gitignore: "*.log\n!important.log\ntrace.*\n",
    queries: @[f"debug.log", f"important.log", f"trace.log",
               f"trace.txt", f"readme"]),

  Case(name: "re-ignore and re-include orderings",
    gitignore: "nfoo\n!nfoo\nnfoo\nnbar\n!nbar\n",
    queries: @[f"nfoo", f"nbar", f"nbaz"]),

  # ------------------------------------------ dirOnly + negation interplay
  Case(name: "star then negated dirOnly",
    gitignore: "*\n!fooz/\n",
    queries: @[d"fooz", f"fooz/bar", f"other"]),

  Case(name: "gitignore-docs example: /* !/foo /foo/* !/foo/bar",
    gitignore: "/*\n!/foo\n/foo/*\n!/foo/bar\n",
    queries: @[f"x", d"foo", f"foo/y", d"foo/bar", f"foo/bar/deep"]),

  Case(name: "data/** trio (t0008 style)",
    gitignore: "data/**\n!data/*.md\n!data/sub/\n",
    queries: @[d"data", f"data/x", f"data/notes.md", d"data/sub",
               f"data/sub/y"]),

  Case(name: "dirOnly: unanchored and anchored",
    gitignore: "frotz/\ndoc/frotz/\n",
    queries: @[d"frotz", d"b/frotz", f"c/frotz", d"doc/frotz",
               d"a2/doc/frotz", f"frotzf"]),

  Case(name: "dirOnly against plain file",
    gitignore: "ddir/\ndfile/\n",
    queries: @[d"ddir", f"ddir/in", f"dfile"]),

  # -------------------------------------------------------------- anchoring
  Case(name: "anchoring: leading, middle, both",
    gitignore: "/top\nmid/name\n/both/x\n",
    queries: @[f"top", f"sub/top", f"mid/name", f"deep/mid/name",
               f"name", f"both/x"]),

  Case(name: "degenerate slashes: foo//",
    gitignore: "foo//\n",
    queries: @[d"foo", f"foo/x"]),

  # -------------------------------------------- ancestors and dead negation
  Case(name: "ancestor: dead negation inside ignored dir",
    gitignore: "build/\n!build/kept\nout/tmp/\n",
    queries: @[d"build", f"build/kept", f"build/other",
               f"out/tmp/x", f"out/tmp/d/y", d"out"]),

  Case(name: "negated prefix is not sticky",
    gitignore: "*\n!inc\n",
    queries: @[d"inc", f"inc/bar"]),

  # -------------------------------------------------- undecided fall-through
  Case(name: "undecided fall-through",
    gitignore: "zzz\n# comment only\n\n!nomatch\n",
    queries: @[f"anything", d"somedir", f"somedir/nested",
               f"nomatch", f"zzz"]),

  # ------------------------------------------------------------------ misc
  Case(name: "single-char and single-segment wildcards",
    gitignore: "?z\nq*e\n",
    queries: @[f"az", f"z", f"a/bz", f"quote", f"qe", f"q/e"]),

  Case(name: "case sensitivity with ignorecase=false",
    gitignore: "CaseTest\n",
    queries: @[f"CaseTest", v"casetest"]),

  # --------------------------- multi-file cases (repo layer, Milestone 5)
  Case(name: "nested: t0008 fixture tree",
    gitignore: "one\nignored-*\ntop-level-dir/\n",
    files: @[("a/.gitignore", "two\n*three\n!*special-three\n"),
             ("a/b/.gitignore", "four\nfive\n# a comment\nsix\n" &
              "ignored-dir/\n# and a blank line:\n\n!on*\n!two\n")],
    queries: @[f"one", f"a/one", f"a/b/one", f"a/two", f"a/b/two", f"two",
               f"a/three", f"a/special-three", f"a/b/four", f"b/four",
               d"top-level-dir", d"a/top-level-dir",
               d"a/b/ignored-dir", f"a/b/ignored-dir/foo", f"a/b/twelve"]),

  Case(name: "nested: anchored pattern scoped to its subdir",
    gitignore: "",
    files: @[("a/b/.gitignore", "/anchored\nmid/x\n")],
    queries: @[f"a/b/anchored", f"anchored", f"a/anchored",
               f"a/b/c/anchored", f"a/b/mid/x", f"mid/x", f"a/mid/x"]),

  Case(name: "info/exclude: applies everywhere, loses to .gitignore",
    gitignore: "!exc\nroot-only\n",
    files: @[(".git/info/exclude", "per-repo\nexc\n")],
    queries: @[f"per-repo", f"sub/per-repo", f"exc", f"sub/exc",
               f"root-only", f"nothing"]),

  Case(name: "sticky: dir ignored via info/exclude kills deeper negation",
    gitignore: "",
    files: @[(".git/info/exclude", "vendor/\n"),
             ("vendor/.gitignore", "!lib.js\n")],
    queries: @[d"vendor", f"vendor/lib.js", f"vendor/other", f"lib.js"]),

  Case(name: "excludesFile: lowest priority, info/exclude trumps it",
    gitignore: "",
    files: @[(".git/info/exclude", "!globalone\nglobaltwo\n")],
    excludesFile: "globalone\n!globaltwo\nglobalthree\n",
    queries: @[f"globalone", f"globaltwo", f"globalthree", f"other",
               f"sub/globalthree"]),

  Case(name: "excludesFile vs root .gitignore",
    gitignore: "!globx\n",
    excludesFile: "globx\ngloby\n",
    queries: @[f"globx", f"globy", f"sub/globx"]),

  Case(name: "deeper file re-includes a dir ignored higher up",
    gitignore: "build/\n",
    files: @[("docs/.gitignore", "!build\n")],
    queries: @[d"build", f"build/x", d"docs/build", f"docs/build/page",
               f"docs/other"]),

  Case(name: "nested dirOnly and unanchored interplay",
    gitignore: "*.o\n",
    files: @[("a/.gitignore", "sub/\n"),
             ("a/sub2/.gitignore", "!keep.o\ntmp2/\n")],
    queries: @[d"a/sub", f"a/sub/x", f"a/sub2/f.o", f"a/sub2/keep.o",
               f"keep.o", d"a/sub2/tmp2", f"a/sub2/tmp2/y", f"a/x.o"]),

  Case(name: "gitignore in subdir only, none at root",
    gitignore: "",
    files: @[("deep/nest/.gitignore", "*.tmp\n!keep.tmp\n")],
    queries: @[f"deep/nest/a.tmp", f"deep/nest/keep.tmp",
               f"deep/nest/more/b.tmp", f"deep/a.tmp", f"a.tmp"]),

  Case(name: "Win32 alias must not load a phantom subdir .gitignore",
    # A trailing-dot prefix ("ba./b") must not pick up ba/.gitignore via
    # Win32 trailing space/dot stripping when the ignore file is probed
    # on disk. Distilled from a Tier-3 fuzzer divergence (Milestone 6):
    # git reports no match for these paths.
    gitignore: "",
    files: @[("ba/.gitignore", "*\n")],
    queries: @[f"ba/b", v"ba./b", v"ba /b", v"ba./x/y"]),
]
