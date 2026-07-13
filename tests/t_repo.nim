## Layer 3 tests: the repository ignore stack and pruning walker.
##
## Ports the t/t0008-ignores.sh scenarios that Milestone 3 deferred
## because they need more than one ignore file: nested .gitignore
## precedence, sub-directory local (anchored) ignores, .git/info/exclude,
## and info/exclude trumping the excludesFile. Index/tracked-file
## scenarios stay out of scope (this library implements `--no-index`
## semantics), as do symlink/submodule handling.
##
## Uses temp dirs (std/os is fine in tests) but never a git binary, so
## `nimble test` stays hermetic. Fixtures are written with `writeFile`
## (byte-exact). NTFS constraints respected: no trailing-space/dot paths
## on disk, no two paths differing only by case. Expected outcomes were
## verified against `git check-ignore -v --non-matching --no-index`; the
## multi-file cases are additionally cross-checked by the Tier-2
## differential harness.

import std/[unittest, options, os, strutils, tempfiles]
import gitignore/repo

proc makeTree(files: openArray[(string, string)]): string =
  ## Creates a temp dir; keys ending in "/" become directories, all
  ## others files with the given byte-exact content (parents created).
  result = createTempDir("gitignore_t_repo_", "")
  for (rel, content) in files:
    let native = result / rel.replace("/", $DirSep)
    if rel.endsWith("/"):
      createDir(native)
    else:
      createDir(parentDir(native))
      writeFile(native, content)

proc collect(s: var IgnoreStack; dir = ""): seq[string] =
  for p in s.walkNotIgnored(dir):
    result.add p

suite "path normalization at the API boundary":
  test "OS paths are accepted and normalized":
    let root = makeTree({".gitignore": "one\n", "a/one": "", "a/two": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("a/one", isDir = false)
    check s.isIgnored("a\\one", isDir = false)          # backslashes
    check s.isIgnored("./a/one", isDir = false)         # leading ./
    check s.isIgnored(root / "a" / "one", isDir = false)  # absolute
    check not s.isIgnored("a/two", isDir = false)
    check not s.isIgnored(root, isDir = true)           # root never ignored

  test "absolute path outside the repo root raises":
    let root = makeTree({".gitignore": "one\n"})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    expect ValueError:
      discard s.isIgnored(parentDir(root) / "elsewhere", isDir = false)

suite "nested .gitignore precedence (t0008)":
  # The t0008 fixture tree, minus index/tracked-file parts.
  const rootIgn = "one\nignored-*\ntop-level-dir/\n"
  const aIgn = "two\n*three\n!*special-three\n"
  const abIgn = "four\nfive\n# a comment\nsix\nignored-dir/\n" &
                "# and a blank line:\n\n!on*\n!two\n"

  proc t0008Tree(): string =
    makeTree({".gitignore": rootIgn, "a/.gitignore": aIgn,
              "a/b/.gitignore": abIgn, "a/b/ignored-dir/foo": ""})

  test "deeper .gitignore wins over shallower":
    let root = t0008Tree()
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("one", isDir = false)
    check s.isIgnored("a/one", isDir = false)
    check not s.isIgnored("a/b/one", isDir = false)   # !on* in a/b
    check s.isIgnored("a/two", isDir = false)
    check not s.isIgnored("a/b/two", isDir = false)   # !two in a/b
    check not s.isIgnored("two", isDir = false)       # a/.gitignore scoped to a/
    check s.isIgnored("a/three", isDir = false)
    check not s.isIgnored("a/special-three", isDir = false)
    check s.isIgnored("a/b/four", isDir = false)
    check not s.isIgnored("b/four", isDir = false)
    check s.isIgnored("top-level-dir", isDir = true)
    check s.isIgnored("a/top-level-dir", isDir = true)  # unanchored dirOnly

  test "explain reports source file, lineNo and pattern (check-ignore -v)":
    let root = t0008Tree()
    defer: removeDir(root)
    var s = newIgnoreStack(root)

    let m1 = s.explain("a/one", isDir = false)
    check m1.isSome
    check m1.get.source == ".gitignore"
    check m1.get.pattern.lineNo == 1
    check m1.get.pattern.original == "one"

    # Comments and blank lines in a/b/.gitignore shift later lineNos,
    # exactly as `git check-ignore -v` reports them.
    let m2 = s.explain("a/b/one", isDir = false)
    check m2.isSome
    check m2.get.source == "a/b/.gitignore"
    check m2.get.pattern.lineNo == 8
    check m2.get.pattern.original == "!on*"
    check m2.get.pattern.negated

    let m3 = s.explain("a/b/twelve", isDir = false)
    check m3.isNone

  test "ancestor decision is reported for paths inside an ignored dir":
    let root = t0008Tree()
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("a/b/ignored-dir/foo", isDir = false)
    let m = s.explain("a/b/ignored-dir/foo", isDir = false)
    check m.isSome
    check m.get.source == "a/b/.gitignore"
    check m.get.pattern.lineNo == 5
    check m.get.pattern.original == "ignored-dir/"

  test "sub-directory local ignore: anchored pattern scoped to its dir":
    let root = makeTree({"a/b/.gitignore": "/anchored\n"})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("a/b/anchored", isDir = false)
    check not s.isIgnored("anchored", isDir = false)
    check not s.isIgnored("a/anchored", isDir = false)
    check not s.isIgnored("a/b/c/anchored", isDir = false)

suite "Win32 phantom ignore files":
  test "trailing-dot prefix dir never loads an aliased .gitignore":
    # On Windows, probing "ba./.gitignore" resolves (via Win32 trailing
    # space/dot stripping) to the existing "ba/.gitignore" — a phantom
    # ignore file for a directory that cannot exist under that name. Git
    # reports no match for paths under "ba."; so must we. On other OSes
    # the file genuinely does not exist, so the same expectation holds.
    # Regression test for a Tier-3 fuzzer divergence (Milestone 6).
    let root = makeTree({"ba/.gitignore": "*\n"})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("ba/b", isDir = false)
    check not s.isIgnored("ba./b", isDir = false)
    check not s.isIgnored("ba /b", isDir = false)
    check s.explain("ba./b", isDir = false).isNone

suite ".git/info/exclude and the excludesFile":
  test "info/exclude is read automatically and applies everywhere":
    let root = makeTree({".git/info/exclude": "per-repo\n",
                         "sub/per-repo": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("per-repo", isDir = false)
    check s.isIgnored("sub/per-repo", isDir = false)
    let m = s.explain("sub/per-repo", isDir = false)
    check m.isSome
    check m.get.source == ".git/info/exclude"
    check m.get.pattern.lineNo == 1

  test "any .gitignore beats info/exclude":
    let root = makeTree({".git/info/exclude": "exc\n",
                         ".gitignore": "!exc\n"})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check not s.isIgnored("exc", isDir = false)
    check s.explain("exc", isDir = false).get.source == ".gitignore"

  test "info/exclude trumps the excludesFile (t0008)":
    let root = makeTree({
      ".git/info/exclude": "!globalone\nglobaltwo\n"})
    defer: removeDir(root)
    # Kept inside the temp root only so removeDir cleans it up; it plays
    # the role of a global file outside the repo.
    let excl = root / "global-excludes.txt"
    writeFile(excl, "globalone\n!globaltwo\nglobalthree\n")
    var s = newIgnoreStack(root, excludesFile = excl)
    check not s.isIgnored("globalone", isDir = false)   # info negation wins
    check s.explain("globalone", isDir = false).get.source ==
      ".git/info/exclude"
    check s.isIgnored("globaltwo", isDir = false)       # info plain wins
    check s.isIgnored("globalthree", isDir = false)     # excludesFile alone
    check s.explain("globalthree", isDir = false).get.source == excl

  test "the excludesFile is strictly opt-in and may be missing":
    let root = makeTree({"x": ""})
    defer: removeDir(root)
    let excl = root / "excl.txt"
    writeFile(excl, "optedin\n")
    var noExcl = newIgnoreStack(root)
    check not noExcl.isIgnored("optedin", isDir = false)
    var withExcl = newIgnoreStack(root, excludesFile = excl)
    check withExcl.isIgnored("optedin", isDir = false)
    var missing = newIgnoreStack(root, excludesFile = root / "nope.txt")
    check not missing.isIgnored("optedin", isDir = false)

suite "cross-file stickiness (prep_exclude)":
  test "dir ignored by one source is sticky: deeper .gitignore invisible":
    let root = makeTree({".git/info/exclude": "vendor/\n",
                         "vendor/.gitignore": "!lib.js\n",
                         "vendor/lib.js": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("vendor", isDir = true)
    check s.isIgnored("vendor/lib.js", isDir = false)  # negation is dead
    let m = s.explain("vendor/lib.js", isDir = false)
    check m.isSome
    check m.get.source == ".git/info/exclude"
    check m.get.pattern.original == "vendor/"

  test "negated prefix decision is not sticky":
    # docs/.gitignore re-includes docs/build, but children of docs/build
    # get no protection from that negation (verified against git: with
    # `*` then `!foo`, foo is included yet foo/bar stays ignored).
    let root = makeTree({".gitignore": "*\n!keep\n", "keep/inner": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check not s.isIgnored("keep", isDir = true)
    check s.isIgnored("keep/inner", isDir = false)

  test "deeper .gitignore re-includes a dir ignored higher up":
    let root = makeTree({".gitignore": "build/\n",
                         "docs/.gitignore": "!build\n",
                         "docs/build/page.html": "", "build/x": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.isIgnored("build", isDir = true)
    check not s.isIgnored("docs/build", isDir = true)
    check not s.isIgnored("docs/build/page.html", isDir = false)

suite "caseInsensitive (core.ignoreCase)":
  test "threaded through stack evaluation":
    let root = makeTree({".gitignore": "FOO\nsub/BAR\n"})
    defer: removeDir(root)
    var cs = newIgnoreStack(root)
    var ci = newIgnoreStack(root, caseInsensitive = true)
    # Queried paths are never created: NTFS is case-insensitive, so two
    # on-disk paths differing only by case cannot coexist anyway.
    check not cs.isIgnored("foo", isDir = false)
    check ci.isIgnored("foo", isDir = false)
    check ci.isIgnored("SUB/bar", isDir = false)
    check not cs.isIgnored("SUB/bar", isDir = false)

suite "walkNotIgnored":
  test "prunes ignored directories and skips .git":
    let root = makeTree({
      ".gitignore": "build/\n*.log\n",
      ".git/config": "", ".git/info/exclude": "",
      "build/artifact.o": "", "build/sub/deep.o": "",
      "src/main.nim": "", "src/debug.log": "",
      "notes.txt": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.collect() == @[".gitignore", "notes.txt", "src", "src/main.nim"]

  test "descends into re-included directories":
    let root = makeTree({
      ".gitignore": "build/\n",
      "docs/.gitignore": "!build\n",
      "docs/build/page.html": "", "build/x": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    check s.collect() == @[".gitignore", "docs", "docs/.gitignore",
                           "docs/build", "docs/build/page.html"]

  test "walking a subdirectory":
    let root = makeTree({
      ".gitignore": "*.log\n",
      "src/main.nim": "", "src/x.log": "", "src/deep/y.nim": "",
      "other/z": ""})
    defer: removeDir(root)
    var s = newIgnoreStack(root)
    # Entries of each directory are yielded before descending.
    check s.collect("src") == @["src/deep", "src/main.nim",
                                "src/deep/y.nim"]
