## Gitignore line parser (Layer 1a).
##
## Parses one line of a `.gitignore` file into a `Pattern` and matches it
## against a relative path. Mirrors git's `dir.c` (`trim_trailing_spaces`
## and `parse_path_pattern`), applying the rules in this exact order:
##
## 1. Strip a trailing `\r` (git reads ignore files this way).
## 2. Blank line or line starting with `#` → no pattern. A line starting
##    with `\#` is NOT a comment: the escape survives into the glob, where
##    wildmatch turns `\#` into a literal hash — exactly like git.
## 3. Strip unescaped trailing **spaces** only (`foo\ ` keeps its escaped
##    space; trailing tabs are never stripped).
## 4. A leading `!` sets `negated` and is removed. A leading `\!` is not
##    negation; the escape survives into the glob.
## 5. A pattern empty after the above (e.g. the line was just `!`) yields
##    no pattern.
## 6. A trailing `/` sets `dirOnly` and is removed.
## 7. If a `/` remains anywhere (leading or middle — the stripped trailing
##    one doesn't count), the pattern is `anchored` to the ignore file's
##    directory. A leading `/` is only an anchor and is stripped. A pattern
##    that is empty at this point (the line was `/` or `//`) matches
##    nothing in git, so it too yields no pattern.
##
## Matching (Layer 1 only — no ancestor-directory walking, that is
## Layer 2's job):
##
## - `dirOnly` patterns match only when `isDir` is true.
## - Anchored patterns are matched against the full `relPath` the way git's
##   `match_pathname` does it: the literal (no-wildcard) prefix of the
##   pattern is compared and consumed first, and wildmatch runs only on the
##   remainders. That prefix consumption is semantic, not an optimization —
##   it can expose a `**` at the start of the remaining pattern, where it
##   gains its slash-crossing meaning: git matches `foo**/bar` against
##   `foobar`, `foox/bar` and `foo/x/y/bar`, while plain wildmatch on the
##   whole strings would treat the glued `foo**` as two ordinary stars
##   (found by the Tier-2 differential harness).
## - Unanchored patterns (which by construction contain no `/`) are matched
##   against the path's last component, at any depth — git's
##   `match_basename`.
##
## Pure string processing: no I/O, std lib only.

import std/[options, strutils]
import wildmatch

export options

type
  Pattern* = object
    negated*: bool           ## leading `!`
    dirOnly*: bool           ## trailing `/`
    anchored*: bool          ## contained a non-trailing slash
    glob: string             ## processed pattern text handed to wildmatch
    prefixLen: int           ## git's nowildcardlen: literal prefix of glob
    original*: string        ## verbatim line, for explain/`-v` output
    lineNo*: int

func simpleLength(s: string): int =
  ## Port of git's simple_length(): length of the leading run of the
  ## pattern that contains no glob-special character (`* ? [ \`).
  while result < s.len and s[result] notin {'*', '?', '[', '\\'}:
    inc result

func foldA(c: char): char {.inline.} =
  ## ASCII-only lowercasing, same folding wildmatch uses.
  if c in {'A'..'Z'}: chr(ord(c) + 32) else: c

func stripTrailingSpaces(s: string): string =
  ## Port of git's trim_trailing_spaces(): removes a trailing run of
  ## unescaped spaces (spaces only — tabs survive). A backslash escapes
  ## the character after it, so `foo\ ` keeps its space; a lone trailing
  ## backslash disables trimming for the whole line.
  var lastSpace = -1
  var i = 0
  while i < s.len:
    case s[i]
    of ' ':
      if lastSpace < 0:
        lastSpace = i
    of '\\':
      inc i
      if i >= s.len:
        return s
      lastSpace = -1
    else:
      lastSpace = -1
    inc i
  if lastSpace >= 0: s[0 ..< lastSpace] else: s

func parsePattern*(line: string; lineNo = 0): Option[Pattern] =
  ## Parses one gitignore line. Returns `none` for blank lines, comments,
  ## and patterns that are empty after stripping (which match nothing).
  var s = line
  if s.len > 0 and s[^1] == '\r':
    s.setLen(s.len - 1)
  if s.len == 0 or s[0] == '#':
    return none(Pattern)
  s = stripTrailingSpaces(s)

  var p = Pattern(original: line, lineNo: lineNo)
  if s.len > 0 and s[0] == '!':
    p.negated = true
    s = s[1 .. ^1]
  if s.len == 0:
    return none(Pattern)
  if s[^1] == '/':
    p.dirOnly = true
    s.setLen(s.len - 1)
  if '/' in s:
    p.anchored = true
    if s[0] == '/':
      s = s[1 .. ^1]
  if s.len == 0:
    # The line was "/", "!/", or "//": git keeps such patterns but they
    # can never match anything, so we drop them here.
    return none(Pattern)
  p.glob = s
  p.prefixLen = simpleLength(s)
  some(p)

func matches*(p: Pattern; relPath: string; isDir: bool;
              caseInsensitive = false): bool =
  ## Matches `relPath` (relative to the ignore file's directory, `/`
  ## separators, no leading `./`) against this single pattern. `negated`
  ## does not affect the result — negation flips the outcome at the
  ## file-evaluation layer, not here.
  if p.dirOnly and not isDir:
    return false
  if p.anchored:
    # Port of git's match_pathname(): compare and consume the literal
    # prefix, then wildmatch only the remainders. See the module docs for
    # why this changes semantics (glued `**` like `foo**/bar`).
    if p.prefixLen > relPath.len:
      return false
    for i in 0 ..< p.prefixLen:
      if p.glob[i] != relPath[i] and
         not (caseInsensitive and foldA(p.glob[i]) == foldA(relPath[i])):
        return false
    if p.prefixLen == p.glob.len and p.prefixLen == relPath.len:
      return true
    wildmatch(p.glob[p.prefixLen .. ^1], relPath[p.prefixLen .. ^1],
              caseInsensitive)
  else:
    let i = relPath.rfind('/')
    let base = if i >= 0: relPath[i + 1 .. ^1] else: relPath
    wildmatch(p.glob, base, caseInsensitive)
