## Unit tests for the gitignore line parser (pattern.nim).
##
## Tricky behaviors (escaped trailing space, "!" alone, "/" alone,
## "foo/" vs "/foo/" vs "a/b/") were verified against
## `git check-ignore -v --no-index` in a temp repo.

import std/[unittest, options]
import gitignore/pattern

suite "parsePattern: line stripping and rejection":
  test "trailing CR is stripped (CRLF files)":
    let p = parsePattern("foo\r").get
    check p.matches("foo", isDir = false)
    check not p.matches("foo\r", isDir = false)

  test "blank lines yield no pattern":
    check parsePattern("").isNone
    check parsePattern("\r").isNone

  test "comment lines yield no pattern":
    check parsePattern("# a comment").isNone
    check parsePattern("#").isNone
    check parsePattern("#foo").isNone

  test "backslash escapes a literal leading hash":
    let p = parsePattern(r"\#foo").get
    check p.matches("#foo", isDir = false)
    check not p.matches("foo", isDir = false)

  test "unescaped trailing spaces are stripped":
    let p = parsePattern("foo   ").get
    check p.matches("foo", isDir = false)
    check not p.matches("foo   ", isDir = false)

  test "escaped trailing space survives":
    let p = parsePattern("foo\\ ").get
    check p.matches("foo ", isDir = false)
    check not p.matches("foo", isDir = false)

  test "unescaped spaces after an escaped one are still stripped":
    # "foo\ " + two plain spaces -> pattern text "foo\ "
    let p = parsePattern("foo\\   ").get
    check p.matches("foo ", isDir = false)
    check not p.matches("foo   ", isDir = false)

  test "trailing tabs are NOT stripped":
    let p = parsePattern("foo\t").get
    check p.matches("foo\t", isDir = false)
    check not p.matches("foo", isDir = false)

  test "line of only spaces yields no pattern":
    check parsePattern("   ").isNone

suite "parsePattern: negation":
  test "leading ! sets negated and is removed":
    let p = parsePattern("!foo").get
    check p.negated
    # matches() ignores negation; it only reports whether the glob hits.
    check p.matches("foo", isDir = false)
    check not p.matches("!foo", isDir = false)

  test "backslash escapes a literal leading bang":
    let p = parsePattern(r"\!foo").get
    check not p.negated
    check p.matches("!foo", isDir = false)
    check not p.matches("foo", isDir = false)

  test "bare ! yields no pattern":
    check parsePattern("!").isNone
    check parsePattern("!   ").isNone
    check parsePattern("!\r").isNone

suite "parsePattern: dirOnly and anchoring flags":
  test "trailing / sets dirOnly":
    let p = parsePattern("foo/").get
    check p.dirOnly
    check not p.anchored

  test "leading / anchors":
    let p = parsePattern("/foo").get
    check p.anchored
    check not p.dirOnly

  test "middle / anchors":
    let p = parsePattern("a/b").get
    check p.anchored

  test "trailing / alone does not anchor":
    check not parsePattern("foo/").get.anchored

  test "no slash: neither anchored nor dirOnly":
    let p = parsePattern("foo").get
    check not p.anchored
    check not p.dirOnly

  test "leading and trailing slash combine":
    let p = parsePattern("/foo/").get
    check p.anchored
    check p.dirOnly

  test "middle and trailing slash combine":
    let p = parsePattern("a/b/").get
    check p.anchored
    check p.dirOnly

  test "negated anchored dirOnly parses fully":
    let p = parsePattern("!/build/").get
    check p.negated and p.anchored and p.dirOnly

  test "bare / and // yield no pattern":
    check parsePattern("/").isNone
    check parsePattern("//").isNone
    check parsePattern("!/").isNone

suite "parsePattern: metadata":
  test "original and lineNo are preserved verbatim":
    let p = parsePattern("!foo/ \r", lineNo = 42).get
    check p.original == "!foo/ \r"
    check p.lineNo == 42
    check p.negated and p.dirOnly

suite "matches: unanchored patterns":
  test "match at any depth against the last component":
    let p = parsePattern("foo").get
    check p.matches("foo", isDir = false)
    check p.matches("a/foo", isDir = false)
    check p.matches("a/b/foo", isDir = false)

  test "no match when only an ancestor component matches":
    # Ancestor-directory semantics belong to Layer 2, not the single
    # pattern: "foo" does not match "foo/bar" by itself.
    let p = parsePattern("foo").get
    check not p.matches("foo/bar", isDir = false)

  test "wildcards apply to the basename at any depth":
    let p = parsePattern("*.txt").get
    check p.matches("notes.txt", isDir = false)
    check p.matches("deep/dir/notes.txt", isDir = false)
    check not p.matches("notes.txt/sub", isDir = false)

suite "matches: anchored patterns":
  test "leading / anchors to the base":
    let p = parsePattern("/foo").get
    check p.matches("foo", isDir = false)
    check not p.matches("a/foo", isDir = false)

  test "middle slash anchors to the base":
    let p = parsePattern("a/b").get
    check p.matches("a/b", isDir = false)
    check not p.matches("x/a/b", isDir = false)

  test "anchored wildcard stays within one directory level":
    let p = parsePattern("doc/*.txt").get
    check p.matches("doc/a.txt", isDir = false)
    check not p.matches("doc/sub/a.txt", isDir = false)
    check not p.matches("x/doc/a.txt", isDir = false)

  test "anchored ** crosses directories":
    let p = parsePattern("doc/**/*.txt").get
    check p.matches("doc/a.txt", isDir = false)
    check p.matches("doc/sub/a.txt", isDir = false)

  test "literal prefix exposes a glued ** (match_pathname semantics)":
    # git's match_pathname consumes the pattern's literal prefix before
    # running wildmatch, so in "foo**/bar" the ** starts the remaining
    # pattern and crosses slashes. Verified against git check-ignore;
    # regression test for a Milestone 4 differential-harness divergence.
    let p = parsePattern("foo**/bar").get
    check p.matches("foobar", isDir = false)
    check p.matches("foox/bar", isDir = false)
    check p.matches("foo/bar", isDir = false)
    check p.matches("foo/x/y/bar", isDir = false)
    check p.matches("foox/y/bar", isDir = false)
    check not p.matches("foobazbar", isDir = false)
    check not p.matches("xfoo/bar", isDir = false)

  test "literal prefix comparison folds case when asked":
    let p = parsePattern("Doc/**/x").get
    check not p.matches("doc/a/x", isDir = false)
    check p.matches("doc/a/x", isDir = false, caseInsensitive = true)

suite "matches: dirOnly":
  test "dirOnly matches only directories":
    let p = parsePattern("foo/").get
    check p.matches("foo", isDir = true)
    check not p.matches("foo", isDir = false)

  test "unanchored dirOnly matches directories at any depth":
    let p = parsePattern("foo/").get
    check p.matches("a/b/foo", isDir = true)
    check not p.matches("a/b/foo", isDir = false)

  test "anchored dirOnly (/foo/) matches only the base directory":
    let p = parsePattern("/foo/").get
    check p.matches("foo", isDir = true)
    check not p.matches("a/foo", isDir = true)
    check not p.matches("foo", isDir = false)

  test "anchored dirOnly (a/b/) matches only that path as a directory":
    let p = parsePattern("a/b/").get
    check p.matches("a/b", isDir = true)
    check not p.matches("a/b", isDir = false)
    check not p.matches("x/a/b", isDir = true)

suite "matches: case folding":
  test "caseInsensitive folds ASCII":
    let p = parsePattern("FOO").get
    check not p.matches("foo", isDir = false)
    check p.matches("foo", isDir = false, caseInsensitive = true)
    check p.matches("dir/Foo", isDir = false, caseInsensitive = true)
