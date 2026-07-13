## Port of git's t/t3070-wildmatch.sh test table.
##
## Each `match` line in the shell script carries four match-function columns:
## wildmatch, iwildmatch, pathmatch, ipathmatch (10-argument rows additionally
## carry four "via ls-files" glob-expansion columns, which are irrelevant here
## — only the wildmatch/iwildmatch function results matter).
##
## We port columns 1 (wildmatch) and 2 (iwildmatch, case-insensitive).
## The pathmatch/ipathmatch columns are SKIPPED: they exercise fnmatch-style
## path matching without WM_PATHNAME (wildcards may match '/'), which is not
## wildmatch semantics and is out of scope for this library.

import std/[unittest, strutils]
import gitignore/wildmatch

type Row = tuple
  glob: int    # expected wildmatch result (1 = match, 0 = no match)
  iglob: int   # expected iwildmatch (case-insensitive) result
  text: string
  pat: string

const rows: seq[Row] = @[
  # Basic wildmatch features
  (1, 1, "foo", "foo"),
  (0, 0, "foo", "bar"),
  (1, 1, "", ""),
  (1, 1, "foo", "???"),
  (0, 0, "foo", "??"),
  (1, 1, "foo", "*"),
  (1, 1, "foo", "f*"),
  (0, 0, "foo", "*f"),
  (1, 1, "foo", "*foo*"),
  (1, 1, "foobar", "*ob*a*r*"),
  (1, 1, "aaaaaaabababab", "*ab"),
  (1, 1, "foo*", r"foo\*"),
  (0, 0, "foobar", r"foo\*bar"),
  (1, 1, r"f\oo", r"f\\oo"),
  (0, 0, r"foo\", r"foo\"),
  (1, 1, "ball", "*[al]?"),
  (0, 0, "ten", "[ten]"),
  (1, 1, "ten", "**[!te]"),
  (0, 0, "ten", "**[!ten]"),
  (1, 1, "ten", "t[a-g]n"),
  (0, 0, "ten", "t[!a-g]n"),
  (1, 1, "ton", "t[!a-g]n"),
  (1, 1, "ton", "t[^a-g]n"),
  (1, 1, "a]b", "a[]]b"),
  (1, 1, "a-b", "a[]-]b"),
  (1, 1, "a]b", "a[]-]b"),
  (0, 0, "aab", "a[]-]b"),
  (1, 1, "aab", "a[]a-]b"),
  (1, 1, "]", "]"),

  # Extended slash-matching features
  (0, 0, "foo/baz/bar", "foo*bar"),
  (0, 0, "foo/baz/bar", "foo**bar"),
  (1, 1, "foobazbar", "foo**bar"),
  (1, 1, "foo/baz/bar", "foo/**/bar"),
  (1, 1, "foo/baz/bar", "foo/**/**/bar"),
  (1, 1, "foo/b/a/z/bar", "foo/**/bar"),
  (1, 1, "foo/b/a/z/bar", "foo/**/**/bar"),
  (1, 1, "foo/bar", "foo/**/bar"),
  (1, 1, "foo/bar", "foo/**/**/bar"),
  (0, 0, "foo/bar", "foo?bar"),
  (0, 0, "foo/bar", "foo[/]bar"),
  (0, 0, "foo/bar", "foo[^a-z]bar"),
  (0, 0, "foo/bar", "f[^eiu][^eiu][^eiu][^eiu][^eiu]r"),
  (1, 1, "foo-bar", "f[^eiu][^eiu][^eiu][^eiu][^eiu]r"),
  (1, 1, "foo", "**/foo"),
  (1, 1, "XXX/foo", "**/foo"),
  (1, 1, "bar/baz/foo", "**/foo"),
  (0, 0, "bar/baz/foo", "*/foo"),
  (0, 0, "foo/bar/baz", "**/bar*"),
  (1, 1, "deep/foo/bar/baz", "**/bar/*"),
  (0, 0, "deep/foo/bar/baz/", "**/bar/*"),
  (1, 1, "deep/foo/bar/baz/", "**/bar/**"),
  (0, 0, "deep/foo/bar", "**/bar/*"),
  (1, 1, "deep/foo/bar/", "**/bar/**"),
  (0, 0, "foo/bar/baz", "**/bar**"),
  (1, 1, "foo/bar/baz/x", "*/bar/**"),
  (0, 0, "deep/foo/bar/baz/x", "*/bar/**"),
  (1, 1, "deep/foo/bar/baz/x", "**/bar/*/*"),

  # Various additional tests
  (0, 0, "acrt", "a[c-c]st"),
  (1, 1, "acrt", "a[c-c]rt"),
  (0, 0, "]", "[!]-]"),
  (1, 1, "a", "[!]-]"),
  (0, 0, "", r"\"),
  (0, 0, r"\", r"\"),
  (0, 0, r"XXX/\", r"*/\"),
  (1, 1, r"XXX/\", r"*/\\"),
  (1, 1, "foo", "foo"),
  (1, 1, "@foo", "@foo"),
  (0, 0, "foo", "@foo"),
  (1, 1, "[ab]", r"\[ab]"),
  (1, 1, "[ab]", "[[]ab]"),
  (1, 1, "[ab]", "[[:]ab]"),
  (0, 0, "[ab]", "[[::]ab]"),
  (1, 1, "[ab]", "[[:digit]ab]"),
  (1, 1, "[ab]", r"[\[:]ab]"),
  (1, 1, "?a?b", r"\??\?b"),
  (1, 1, "abc", r"\a\b\c"),
  (0, 0, "foo", ""),
  (1, 1, "foo/bar/baz/to", "**/t[o]"),

  # Character class tests
  (1, 1, "a1B", "[[:alpha:]][[:digit:]][[:upper:]]"),
  (0, 1, "a", "[[:digit:][:upper:][:space:]]"),
  (1, 1, "A", "[[:digit:][:upper:][:space:]]"),
  (1, 1, "1", "[[:digit:][:upper:][:space:]]"),
  (0, 0, "1", "[[:digit:][:upper:][:spaci:]]"),
  (1, 1, " ", "[[:digit:][:upper:][:space:]]"),
  (0, 0, ".", "[[:digit:][:upper:][:space:]]"),
  (1, 1, ".", "[[:digit:][:punct:][:space:]]"),
  (1, 1, "5", "[[:xdigit:]]"),
  (1, 1, "f", "[[:xdigit:]]"),
  (1, 1, "D", "[[:xdigit:]]"),
  (1, 1, "_", "[[:alnum:][:alpha:][:blank:][:cntrl:][:digit:][:graph:][:lower:][:print:][:punct:][:space:][:upper:][:xdigit:]]"),
  (1, 1, ".", "[^[:alnum:][:alpha:][:blank:][:cntrl:][:digit:][:lower:][:space:][:upper:][:xdigit:]]"),
  (1, 1, "5", "[a-c[:digit:]x-z]"),
  (1, 1, "b", "[a-c[:digit:]x-z]"),
  (1, 1, "y", "[a-c[:digit:]x-z]"),
  (0, 0, "q", "[a-c[:digit:]x-z]"),

  # Additional tests, including some malformed wildmatch patterns
  (1, 1, "]", r"[\\-^]"),
  (0, 0, "[", r"[\\-^]"),
  (1, 1, "-", r"[\-_]"),
  (1, 1, "]", r"[\]]"),
  (0, 0, r"\]", r"[\]]"),
  (0, 0, r"\", r"[\]]"),
  (0, 0, "ab", "a[]b"),
  (0, 0, "a[]b", "a[]b"),
  (0, 0, "ab[", "ab["),
  (0, 0, "ab", "[!"),
  (0, 0, "ab", "[-"),
  (1, 1, "-", "[-]"),
  (0, 0, "-", "[a-"),
  (0, 0, "-", "[!a-"),
  (1, 1, "-", "[--A]"),
  (1, 1, "5", "[--A]"),
  (1, 1, " ", "[ --]"),
  (1, 1, "$", "[ --]"),
  (1, 1, "-", "[ --]"),
  (0, 0, "0", "[ --]"),
  (1, 1, "-", "[---]"),
  (1, 1, "-", "[------]"),
  (0, 0, "j", "[a-e-n]"),
  (1, 1, "-", "[a-e-n]"),
  (1, 1, "a", "[!------]"),
  (0, 0, "[", "[]-a]"),
  (1, 1, "^", "[]-a]"),
  (0, 0, "^", "[!]-a]"),
  (1, 1, "[", "[!]-a]"),
  (1, 1, "^", "[a^bc]"),
  (1, 1, "-b]", "[a-]b]"),
  (0, 0, r"\", r"[\]"),
  (1, 1, r"\", r"[\\]"),
  (0, 0, r"\", r"[!\\]"),
  (1, 1, "G", r"[A-\\]"),
  (0, 0, "aaabbb", "b*a"),
  (0, 0, "aabcaa", "*ba*"),
  (1, 1, ",", "[,]"),
  (1, 1, ",", r"[\\,]"),
  (1, 1, r"\", r"[\\,]"),
  (1, 1, "-", "[,-.]"),
  (0, 0, "+", "[,-.]"),
  (0, 0, "-.]", "[,-.]"),
  (1, 1, "2", r"[\1-\3]"),
  (1, 1, "3", r"[\1-\3]"),
  (0, 0, "4", r"[\1-\3]"),
  (1, 1, r"\", r"[[-\]]"),
  (1, 1, "[", r"[[-\]]"),
  (1, 1, "]", r"[[-\]]"),
  (0, 0, "-", r"[[-\]]"),

  # Test recursion
  (1, 1, "-adobe-courier-bold-o-normal--12-120-75-75-m-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*"),
  (0, 0, "-adobe-courier-bold-o-normal--12-120-75-75-X-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*"),
  (0, 0, "-adobe-courier-bold-o-normal--12-120-75-75-/-70-iso8859-1", "-*-*-*-*-*-*-12-*-*-*-m-*-*-*"),
  (1, 1, "XXX/adobe/courier/bold/o/normal//12/120/75/75/m/70/iso8859/1", "XXX/*/*/*/*/*/*/12/*/*/*/m/*/*/*"),
  (0, 0, "XXX/adobe/courier/bold/o/normal//12/120/75/75/X/70/iso8859/1", "XXX/*/*/*/*/*/*/12/*/*/*/m/*/*/*"),
  (1, 1, "abcd/abcdefg/abcdefghijk/abcdefghijklmnop.txt", "**/*a*b*g*n*t"),
  (0, 0, "abcd/abcdefg/abcdefghijk/abcdefghijklmnop.txtz", "**/*a*b*g*n*t"),
  (0, 0, "foo", "*/*/*"),
  (0, 0, "foo/bar", "*/*/*"),
  (1, 1, "foo/bba/arr", "*/*/*"),
  (0, 0, "foo/bb/aa/rr", "*/*/*"),
  (1, 1, "foo/bb/aa/rr", "**/**/**"),
  (1, 1, "abcXdefXghi", "*X*i"),
  (0, 0, "ab/cXd/efXg/hi", "*X*i"),
  (1, 1, "ab/cXd/efXg/hi", "*/*X*/*/*i"),
  (1, 1, "ab/cXd/efXg/hi", "**/*X*/**/*i"),

  # Extra pathmatch tests (wildmatch/iwildmatch columns only)
  (0, 0, "foo", "fo"),
  (1, 1, "foo/bar", "foo/bar"),
  (1, 1, "foo/bar", "foo/*"),
  (0, 0, "foo/bba/arr", "foo/*"),
  (1, 1, "foo/bba/arr", "foo/**"),
  (0, 0, "foo/bba/arr", "foo*"),
  (0, 0, "foo/bba/arr", "foo**"),
  (0, 0, "foo/bba/arr", "foo/*arr"),
  (0, 0, "foo/bba/arr", "foo/**arr"),
  (0, 0, "foo/bba/arr", "foo/*z"),
  (0, 0, "foo/bba/arr", "foo/**z"),
  (0, 0, "foo/bar", "foo?bar"),
  (0, 0, "foo/bar", "foo[/]bar"),
  (0, 0, "foo/bar", "foo[^a-z]bar"),
  (0, 0, "ab/cXd/efXg/hi", "*Xg*i"),

  # Extra case-sensitivity tests
  (0, 1, "a", "[A-Z]"),
  (1, 1, "A", "[A-Z]"),
  (0, 1, "A", "[a-z]"),
  (1, 1, "a", "[a-z]"),
  (0, 1, "a", "[[:upper:]]"),
  (1, 1, "A", "[[:upper:]]"),
  (0, 1, "A", "[[:lower:]]"),
  (1, 1, "a", "[[:lower:]]"),
  (0, 1, "A", "[B-Za]"),
  (1, 1, "a", "[B-Za]"),
  (0, 1, "A", "[B-a]"),
  (1, 1, "a", "[B-a]"),
  (0, 1, "z", "[Z-y]"),
  (1, 1, "Z", "[Z-y]"),
]

suite "t3070 wildmatch table":
  test "wildmatch (case-sensitive)":
    var bad: seq[string] = @[]
    for i, r in rows:
      let got = wildmatch(r.pat, r.text)
      if got != (r.glob == 1):
        bad.add "row " & $i & ": wildmatch(" & escape(r.pat) & ", " &
                escape(r.text) & ") = " & $got & ", expected " & $r.glob
    for b in bad:
      echo b
    check bad.len == 0

  test "iwildmatch (case-insensitive)":
    var bad: seq[string] = @[]
    for i, r in rows:
      let got = wildmatch(r.pat, r.text, caseInsensitive = true)
      if got != (r.iglob == 1):
        bad.add "row " & $i & ": iwildmatch(" & escape(r.pat) & ", " &
                escape(r.text) & ") = " & $got & ", expected " & $r.iglob
    for b in bad:
      echo b
    check bad.len == 0

  test "matching does not exhibit exponential behavior":
    # Mirrors the final t3070 test: relies on wildmatch.c's abort codes to
    # prune the star-backtracking search. Without them this hangs.
    let text = repeat('a', 61) & "b"
    check not wildmatch("*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a", text)
