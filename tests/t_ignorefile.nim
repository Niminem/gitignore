## Layer 2 tests: whole-file parsing + last-match-wins evaluation.
##
## The first half ports the scenarios from git's t/t0008-ignores.sh that
## are expressible with a SINGLE ignore file. Deferred to Milestone 5
## (repository layer), because they need machinery beyond one file:
##   - nested .gitignore precedence (a/.gitignore vs a/b/.gitignore,
##     "sub-directory local ignore", "--stdin from subdirectory", ...)
##   - .git/info/exclude and core.excludesFile ("global ignore",
##     "info/exclude trumps core.excludesfile")
##   - index interaction ("tracked file not ignored" — we implement
##     --no-index semantics only)
##   - symlink/submodule handling and check-ignore CLI-argument errors
##     (out of scope for a library entirely)
##
## Expected outcomes below were verified against
## `git check-ignore -v --non-matching --no-index` in a temp repo.

import std/[unittest, options]
import gitignore/ignorefile

# Convenience: evaluate content directly.
proc ev(content, relPath: string; isDir: bool;
        caseInsensitive = false): MatchKind =
  parseIgnoreFile(content).match(relPath, isDir, caseInsensitive)

proc why(content, relPath: string; isDir: bool): Option[Pattern] =
  parseIgnoreFile(content).explain(relPath, isDir = isDir)

suite "parseIgnoreFile":
  test "keeps patterns in file order with 1-based line numbers":
    let f = parseIgnoreFile("one\nignored-*\ntop-level-dir/\n")
    check f.patterns.len == 3
    check f.patterns[0].lineNo == 1
    check f.patterns[1].lineNo == 2
    check f.patterns[2].lineNo == 3
    check f.patterns[2].dirOnly

  test "blank lines and comments are skipped but still count for lineNo":
    # Mirrors the a/b/.gitignore fixture from t0008, whose comment and
    # blank line exist precisely to shift later line numbers.
    let f = parseIgnoreFile("""four
five
# this comment should affect the line numbers
six
ignored-dir/
# and so should this blank line:

!on*
!two
""")
    check f.patterns.len == 6
    check f.patterns[3].lineNo == 5   # ignored-dir/
    check f.patterns[4].lineNo == 8   # !on*
    check f.patterns[4].negated
    check f.patterns[5].lineNo == 9   # !two

  test "missing final newline is tolerated":
    let f = parseIgnoreFile("one\ntwo")
    check f.patterns.len == 2
    check f.patterns[1].lineNo == 2

  test "CRLF content parses like git reads it":
    let f = parseIgnoreFile("one\r\n# comment\r\n!two\r\n")
    check f.patterns.len == 2
    check f.patterns[0].lineNo == 1
    check f.patterns[1].lineNo == 3
    check f.patterns[1].negated
    check f.match("one", isDir = false) == mkIgnored
    check f.match("two", isDir = false) == mkIncluded

  test "empty content yields no patterns":
    check parseIgnoreFile("").patterns.len == 0
    check parseIgnoreFile("\n\n# only comments\n").patterns.len == 0

  test "basePath is carried as metadata":
    check parseIgnoreFile("x\n").basePath == ""
    check parseIgnoreFile("x\n", basePath = "a/b").basePath == "a/b"

suite "match: last-match-wins ordering":
  test "later pattern overrides earlier one":
    check ev("foo\n!foo\n", "foo", isDir = false) == mkIncluded
    check ev("!foo\nfoo\n", "foo", isDir = false) == mkIgnored

  test "negation re-include: *.log then !keep.log":
    let f = parseIgnoreFile("*.log\n!keep.log\n")
    check f.match("debug.log", isDir = false) == mkIgnored
    check f.match("keep.log", isDir = false) == mkIncluded
    check f.match("sub/dir/debug.log", isDir = false) == mkIgnored
    check f.match("sub/dir/keep.log", isDir = false) == mkIncluded

  test "re-exclude after re-include":
    let f = parseIgnoreFile("*.log\n!keep.log\nkeep.log\n")
    check f.match("keep.log", isDir = false) == mkIgnored

suite "match: mkUndecided fall-through":
  test "no pattern matches":
    let f = parseIgnoreFile("one\nignored-*\ntop-level-dir/\n")
    check f.match("non-existent", isDir = false) == mkUndecided
    check f.match("not-ignored", isDir = false) == mkUndecided
    check f.match("a/not-ignored", isDir = false) == mkUndecided

  test "empty file decides nothing":
    check ev("", "anything", isDir = false) == mkUndecided

  test "a negated pattern that never matched does not include":
    check ev("!foo\n", "bar", isDir = false) == mkUndecided

  test "bare negation of an unmatched path is undecided, not included":
    # git: `!foo` alone, query foo/bar -> ::	foo/bar (undecided).
    check ev("!foo\n", "foo/bar", isDir = false) == mkUndecided

suite "match: ancestor directories":
  test "dirOnly pattern ignores everything below the directory":
    # git T1: build/ ignores build, build/kept, build/sub/x.
    let f = parseIgnoreFile("build/\n!kept\n")
    check f.match("build", isDir = true) == mkIgnored
    check f.match("build/kept", isDir = false) == mkIgnored
    check f.match("build/sub/x", isDir = false) == mkIgnored
    check f.match("build/sub", isDir = true) == mkIgnored
    check f.match("kept", isDir = false) == mkIncluded
    check f.match("other", isDir = false) == mkUndecided

  test "unanchored file pattern also ignores as an ancestor dir":
    # git T5: pattern "foo", query foo/bar -> ignored by line 1.
    check ev("foo\n", "foo/bar", isDir = false) == mkIgnored
    check ev("foo\n", "foo/bar/baz", isDir = true) == mkIgnored

  test "anchored pattern ignores as an ancestor":
    let f = parseIgnoreFile("a/b\n")
    check f.match("a/b/c", isDir = false) == mkIgnored
    check f.match("x/a/b/c", isDir = false) == mkUndecided

  test "dead negation: cannot re-include inside an ignored directory":
    # git T2: build/ then !build/kept -> build/kept still ignored (line 1).
    check ev("build/\n!build/kept\n", "build/kept", isDir = false) == mkIgnored
    # git T1: unanchored !kept is equally dead under build/.
    check ev("build/\n!kept\n", "build/kept", isDir = false) == mkIgnored

  test "negated prefix match is not sticky":
    # git T6: * then !foo -> foo included, but foo/bar ignored by *.
    let f = parseIgnoreFile("*\n!foo\n")
    check f.match("foo", isDir = true) == mkIncluded
    check f.match("foo/bar", isDir = false) == mkIgnored

suite "match: dirOnly + negation interplay":
  test "dirOnly negation re-includes the directory but not files":
    # git B: * then !foo/ -> foo (dir) included, foo/bar and baz ignored.
    let f = parseIgnoreFile("*\n!foo/\n")
    check f.match("foo", isDir = true) == mkIncluded
    check f.match("foo", isDir = false) == mkIgnored
    check f.match("foo/bar", isDir = false) == mkIgnored
    check f.match("baz", isDir = false) == mkIgnored

  test "dirOnly pattern does not match a plain file":
    let f = parseIgnoreFile("top-level-dir/\n")
    check f.match("top-level-dir", isDir = true) == mkIgnored
    check f.match("top-level-dir", isDir = false) == mkUndecided

suite "explain":
  test "reports the deciding pattern with original text and lineNo":
    let f = parseIgnoreFile("*.log\n!keep.log\n")
    let d = f.explain("keep.log", isDir = false)
    check d.isSome
    check d.get.original == "!keep.log"
    check d.get.lineNo == 2
    let d2 = f.explain("debug.log", isDir = false)
    check d2.get.original == "*.log"
    check d2.get.lineNo == 1

  test "returns none when nothing matches":
    check why("*.log\n", "readme.md", isDir = false).isNone

  test "ancestor decision reports the ancestor's pattern":
    # git T1: `git check-ignore -v` prints ".gitignore:1:build/" for
    # build/kept and build/sub/x.
    let f = parseIgnoreFile("build/\n!kept\n")
    for p in ["build", "build/kept", "build/sub/x"]:
      let d = f.explain(p, isDir = p == "build")
      check d.isSome
      check d.get.original == "build/"
      check d.get.lineNo == 1

  test "comments and blanks shift reported line numbers (t0008 fixture)":
    let f = parseIgnoreFile("""four
five
# this comment should affect the line numbers
six
ignored-dir/
# and so should this blank line:

!on*
!two
""")
    # git: "nested include of negated pattern with -v" expects
    # a/b/.gitignore:8:!on* for path one (relative to a/b).
    let one = f.explain("one", isDir = false)
    check one.get.original == "!on*"
    check one.get.lineNo == 8
    let two = f.explain("two", isDir = false)
    check two.get.original == "!two"
    check two.get.lineNo == 9
    # git: "multiple files inside ignored sub-directory with -v" expects
    # a/b/.gitignore:5:ignored-dir/ for every path under ignored-dir.
    for p in ["ignored-dir/foo", "ignored-dir/twoooo", "ignored-dir/seven"]:
      let d = f.explain(p, isDir = false)
      check d.get.original == "ignored-dir/"
      check d.get.lineNo == 5

suite "caseInsensitive threading":
  test "match folds ASCII when asked":
    let f = parseIgnoreFile("FOO\n!KEEP.LOG\n*.log\n")
    check f.match("foo", isDir = false) == mkUndecided
    check f.match("foo", isDir = false, caseInsensitive = true) == mkIgnored
    check f.match("dir/Foo", isDir = false, caseInsensitive = true) == mkIgnored

  test "ancestor walk folds too":
    check ev("BUILD/\n", "build/x", isDir = false) == mkUndecided
    check ev("BUILD/\n", "build/x", isDir = false,
             caseInsensitive = true) == mkIgnored

  test "explain folds too":
    let f = parseIgnoreFile("*.LOG\n")
    check f.explain("a.log", isDir = false).isNone
    check f.explain("a.log", isDir = false,
                    caseInsensitive = true).get.lineNo == 1

############################################################################
# Ported t0008 scenarios (single-ignore-file subset)

suite "t0008: standard ignores (top-level .gitignore fixture)":
  # cat <<EOF >.gitignore
  #   one
  #   ignored-*
  #   top-level-dir/
  # EOF
  let f = parseIgnoreFile("one\nignored-*\ntop-level-dir/\n")

  test "non-existent file not ignored":
    check f.match("non-existent", isDir = false) == mkUndecided

  test "non-existent file ignored (.gitignore:1:one)":
    let d = f.explain("one", isDir = false)
    check f.match("one", isDir = false) == mkIgnored
    check d.get.original == "one" and d.get.lineNo == 1

  test "existing untracked file not ignored":
    check f.match("not-ignored", isDir = false) == mkUndecided

  test "untracked file ignored (.gitignore:2:ignored-*)":
    let d = f.explain("ignored-and-untracked", isDir = false)
    check d.get.original == "ignored-*" and d.get.lineNo == 2

  test "tracked file shown as ignored with --no-index":
    # We always implement --no-index semantics, so this matches too.
    check f.match("ignored-but-in-index", isDir = false) == mkIgnored

  test "unanchored patterns apply in subdirs (a/one, a/ignored-*)":
    check f.match("a/one", isDir = false) == mkIgnored
    check f.match("a/not-ignored", isDir = false) == mkUndecided
    check f.match("a/ignored-and-untracked", isDir = false) == mkIgnored

  test "existing file and directory (one, top-level-dir)":
    check f.match("one", isDir = false) == mkIgnored
    check f.match("top-level-dir", isDir = true) == mkIgnored

suite "t0008: sub-directory fixtures collapsed to one file":
  test "a/.gitignore: two*, *three (paths relative to a)":
    let f = parseIgnoreFile("two*\n*three\n")
    check f.match("3-three", isDir = false) == mkIgnored
    check f.explain("3-three", isDir = false).get.original == "*three"
    check f.match("three-not-this-one", isDir = false) == mkUndecided
    check f.match("b/twooo", isDir = false) == mkIgnored
    check f.explain("b/twooo", isDir = false).get.lineNo == 1

  test "a/b/.gitignore: negations and ignored-dir (paths relative to a/b)":
    let f = parseIgnoreFile(
      "four\nfive\n# this comment should affect the line numbers\nsix\n" &
      "ignored-dir/\n# and so should this blank line:\n\n!on*\n!two\n")
    check f.match("on", isDir = false) == mkIncluded
    check f.match("one", isDir = false) == mkIncluded
    check f.match("one one", isDir = false) == mkIncluded
    check f.match("one\"three", isDir = false) == mkIncluded
    check f.match("two", isDir = false) == mkIncluded
    check f.match("not-ignored", isDir = false) == mkUndecided
    check f.match("four", isDir = false) == mkIgnored
    check f.match("ignored-dir", isDir = true) == mkIgnored
    check f.match("ignored-dir/foo", isDir = false) == mkIgnored

suite "t0008: exact prefix matching":
  test "with root (/git/)":
    let f = parseIgnoreFile("/git/\n")
    check f.match("git", isDir = true) == mkIgnored
    check f.match("git/foo", isDir = false) == mkIgnored
    check f.match("git-foo", isDir = true) == mkUndecided
    check f.match("git-foo/bar", isDir = false) == mkUndecided

  test "without root (git/)":
    let f = parseIgnoreFile("git/\n")
    check f.match("git", isDir = true) == mkIgnored
    check f.match("git/foo", isDir = false) == mkIgnored
    check f.match("git-foo", isDir = true) == mkUndecided
    check f.match("git-foo/bar", isDir = false) == mkUndecided

suite "t0008: directories and ** matches":
  # Verified against git (test A): file lines are .gitignore:1:data/**,
  # *.txt re-includes are .gitignore:3:!data/**/*.txt.
  let f = parseIgnoreFile("data/**\n!data/**/\n!data/**/*.txt\n")

  test "plain files under data/ are ignored":
    check f.match("file", isDir = false) == mkUndecided
    for p in ["data/file", "data/data1/file1", "data/data2/file2"]:
      check f.match(p, isDir = false) == mkIgnored
      check f.explain(p, isDir = false).get.lineNo == 1

  test "*.txt files are re-included":
    for p in ["data/data1/file1.txt", "data/data2/file2.txt"]:
      check f.match(p, isDir = false) == mkIncluded
      check f.explain(p, isDir = false).get.lineNo == 3

  test "directories are re-included so the walk can descend":
    check f.match("data/data1", isDir = true) == mkIncluded

suite "t0008: ** after a literal prefix (match_pathname semantics)":
  test "foo**/bar":
    # git consumes the literal prefix "foo" before wildmatch, so the glued
    # "**" becomes a leading "**/" and crosses slashes — all verified with
    # git check-ignore (Milestone 4 differential harness divergence fix).
    let f = parseIgnoreFile("foo**/bar\n")
    check f.match("foo/bar", isDir = false) == mkIgnored
    check f.match("foobar", isDir = false) == mkIgnored
    check f.match("foox/bar", isDir = false) == mkIgnored
    check f.match("foo/x/bar", isDir = false) == mkIgnored
    check f.match("foo/x/y/bar", isDir = false) == mkIgnored
    check f.match("foox/y/bar", isDir = false) == mkIgnored
    check f.match("foobazbar", isDir = false) == mkUndecided
    check f.match("xfoo/bar", isDir = false) == mkUndecided

suite "t0008: whitespace handling":
  test "trailing whitespace is ignored":
    let f = parseIgnoreFile("whitespace/trailing   \n")
    check f.match("whitespace/trailing", isDir = false) == mkIgnored
    check f.match("whitespace/untracked", isDir = false) == mkUndecided

  test "quoting allows trailing whitespace":
    # Verified against git (test C): pattern `esc\ \ ` matches "esc  ".
    let f = parseIgnoreFile("esc\\ \\ \n")
    check f.match("esc  ", isDir = false) == mkIgnored
    check f.match("esc", isDir = false) == mkUndecided
