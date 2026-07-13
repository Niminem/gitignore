## Gitignore file evaluation (Layer 2).
##
## Parses a whole `.gitignore` buffer into an ordered pattern list and
## evaluates paths against it with git's semantics:
##
## - **Last match wins.** Patterns are scanned last-to-first; the first
##   hit decides: negated pattern → `mkIncluded`, plain → `mkIgnored`,
##   no hit → `mkUndecided` (fall through to a lower-priority source).
## - **Ancestor directories.** A path is ignored when a pattern matches
##   the path itself *or any ancestor directory* of it. Evaluation walks
##   down the path's `/`-separated prefixes, testing each prefix as a
##   directory. The first prefix decided *ignored* settles the whole
##   path — which also makes deeper negations dead: `!kept` cannot
##   re-include `build/kept` when `build/` is ignored. A prefix decided
##   *included* by a negation is not sticky; evaluation simply continues
##   deeper (verified against `git check-ignore`: with `*` then `!foo`,
##   `foo` is included but `foo/bar` is still ignored by `*`).
## - `dirOnly` patterns only match when the candidate (or the prefix
##   under test, which is a directory by construction) is a directory.
##
## `explain` reports the deciding pattern — the equivalent of
## `git check-ignore -v --no-index` output, including the ancestor case,
## where git prints the pattern that ignored the ancestor directory.
##
## Pure string processing: no I/O, std lib only. `basePath` is carried
## as metadata for Layer 3; all match inputs are paths relative to the
## ignore file's own directory (`/` separators, no leading `./`).

import std/[options, strutils]
import pattern

export pattern

type
  IgnoreFile* = object
    patterns*: seq[Pattern]  ## in file order
    basePath*: string        ## dir the file lives in, `/` separators, "" = root

  MatchKind* = enum
    mkUndecided  ## no pattern matched → fall through to lower-priority source
    mkIgnored    ## matched a plain pattern
    mkIncluded   ## matched a negated (`!`) pattern

func parseIgnoreFile*(content: string; basePath = ""): IgnoreFile =
  ## Parses a whole ignore-file buffer. Lines are split on `\n` exactly
  ## like git reads the file (a trailing `\r` is stripped per line, so
  ## CRLF content works; a missing final newline is fine). `lineNo` is
  ## 1-based and counts every physical line, so blanks and comments
  ## shift the numbers of later patterns just as `git check-ignore -v`
  ## reports them.
  result.basePath = basePath
  var lineNo = 0
  for line in content.split('\n'):
    inc lineNo
    let p = parsePattern(line, lineNo)
    if p.isSome:
      result.patterns.add p.get

func lastMatchingPattern(f: IgnoreFile; relPath: string; isDir: bool;
                         caseInsensitive: bool): Option[Pattern] =
  for i in countdown(f.patterns.high, 0):
    if f.patterns[i].matches(relPath, isDir, caseInsensitive):
      return some(f.patterns[i])
  none(Pattern)

func explain*(f: IgnoreFile; relPath: string; isDir: bool;
              caseInsensitive = false): Option[Pattern] =
  ## Returns the pattern that decides `relPath`, or `none` when no
  ## pattern applies — what `git check-ignore -v --no-index` would
  ## print. When an ancestor directory is ignored, the ancestor's
  ## deciding pattern is returned (the shallowest ignored prefix wins,
  ## mirroring git's `prep_exclude`).
  for i in 0 ..< relPath.len:
    if relPath[i] == '/':
      let m = f.lastMatchingPattern(relPath[0 ..< i], isDir = true,
                                    caseInsensitive)
      if m.isSome and not m.get.negated:
        return m
  f.lastMatchingPattern(relPath, isDir, caseInsensitive)

func match*(f: IgnoreFile; relPath: string; isDir: bool;
            caseInsensitive = false): MatchKind =
  ## Evaluates `relPath` (relative to the ignore file's directory, `/`
  ## separators, no leading `./`) against the whole file.
  let m = f.explain(relPath, isDir, caseInsensitive)
  if m.isNone: mkUndecided
  elif m.get.negated: mkIncluded
  else: mkIgnored
