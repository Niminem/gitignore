## Git's `wildmatch` glob matcher (Layer 1b).
##
## A faithful port of `wildmatch.c` from the git source tree — NOT POSIX
## fnmatch. Git's `WM_PATHNAME` flag is always in effect here, because
## gitignore matching always sets it:
##
## - `*`, `?`, and bracket expressions never match `/`.
## - `**` is special in exactly three positions: leading `**/`, trailing
##   `/**`, and infix `/**/`. Infix `/**/` also matches zero directories
##   (`a/**/b` matches `a/b`). Glued to anything else (`a**b`) it degrades
##   to two ordinary `*`s.
## - Bracket expressions: ranges (`[a-z]`), negation via leading `!` or `^`,
##   `]` as first char is a literal, the 12 POSIX classes (`[:alnum:]` ...
##   `[:xdigit:]`, ASCII-only), and `\x` escapes inside brackets.
##   An unterminated `[` or a malformed `[:class:]` aborts the whole match
##   (matches nothing) — this is what git's own t3070 table demands, even
##   though "unterminated `[` is a literal" is often claimed.
## - `\x` escapes any character `x` to a literal.
## - `caseInsensitive` mirrors git's `WM_CASEFOLD`: ASCII-only folding.
##
## Pure string matching: no I/O, no filesystem access, std lib only.

# Internal result codes, mirroring wildmatch.c. The two abort codes make the
# star backtracking loop terminate early instead of degenerating into
# exponential retries.
const
  wmAbortAll = -1        ## give up the whole match
  wmAbortToStarStar = -2 ## give up back to the nearest slash-crossing star
  wmMatch = 0
  wmNoMatch = 1

# ASCII-only character classification. Git applies C ctype macros to bytes;
# the POSIX classes below are their ASCII subsets, which is all git relies on.
func isUpperA(c: char): bool {.inline.} = c in {'A'..'Z'}
func isLowerA(c: char): bool {.inline.} = c in {'a'..'z'}
func isDigitA(c: char): bool {.inline.} = c in {'0'..'9'}
func isAlphaA(c: char): bool {.inline.} = c in {'A'..'Z', 'a'..'z'}
func isAlnumA(c: char): bool {.inline.} = isAlphaA(c) or isDigitA(c)
func isBlankA(c: char): bool {.inline.} = c in {' ', '\t'}
func isSpaceA(c: char): bool {.inline.} = c in {' ', '\t', '\n', '\v', '\f', '\r'}
func isCntrlA(c: char): bool {.inline.} = c in {'\0'..'\x1F', '\x7F'}
func isPrintA(c: char): bool {.inline.} = c in {' '..'~'}
func isGraphA(c: char): bool {.inline.} = c in {'!'..'~'}
func isPunctA(c: char): bool {.inline.} = isGraphA(c) and not isAlnumA(c)
func isXdigitA(c: char): bool {.inline.} = c in {'0'..'9', 'a'..'f', 'A'..'F'}

func toLowerA(c: char): char {.inline.} =
  if isUpperA(c): chr(ord(c) + 32) else: c

func toUpperA(c: char): char {.inline.} =
  if isLowerA(c): chr(ord(c) - 32) else: c

func isGlobSpecial(c: char): bool {.inline.} =
  c in {'*', '?', '[', '\\'}

func dowild(pattern, text: string; pStart, tStart: int; fold: bool): int =
  ## Port of wildmatch.c's dowild(). `pStart`/`tStart` play the role of the
  ## C pointers; out-of-range reads yield '\0' like the C NUL terminator.
  ## `pStart` is also remembered as the start of the current (sub)pattern,
  ## which the `**` detection needs ("prev_p - pattern < 2" in C).
  var p = pStart
  var t = tStart

  template patAt(i: int): char =
    (if i < pattern.len: pattern[i] else: '\0')
  template txtAt(i: int): char =
    (if i < text.len: text[i] else: '\0')

  while p < pattern.len:
    var pch = pattern[p]
    var tch = txtAt(t)
    if tch == '\0' and pch != '*':
      return wmAbortAll
    if fold:
      tch = toLowerA(tch)
      pch = toLowerA(pch)

    case pch
    of '\\':
      # Literal match with the following character. A trailing lone escape
      # yields '\0' here, which can never equal tch (tch != '\0' above).
      # Note git does not case-fold the escaped pattern character.
      inc p
      pch = patAt(p)
      if tch != pch:
        return wmNoMatch
    of '?':
      if tch == '/':
        return wmNoMatch
    of '*':
      inc p
      var matchSlash: bool
      if patAt(p) == '*':
        let prevP = p          # index of the second star
        inc p
        while patAt(p) == '*': inc p
        if (prevP - pStart < 2 or pattern[prevP - 2] == '/') and
           (patAt(p) == '\0' or patAt(p) == '/' or
            (patAt(p) == '\\' and patAt(p + 1) == '/')):
          # Leading "**/", trailing "/**", or infix "/**/": may cross
          # slashes. Infix "/**/" must also match zero directories, so
          # first try skipping the "**/" part entirely.
          if patAt(p) == '/' and
             dowild(pattern, text, p + 1, t, fold) == wmMatch:
            return wmMatch
          matchSlash = true
        else:
          # "**" glued to something else (a**b) degrades to two plain stars.
          matchSlash = false
      else:
        matchSlash = false

      if patAt(p) == '\0':
        # Trailing "**" matches everything; trailing "*" matches only if
        # no slash remains in the text.
        if not matchSlash:
          for i in t ..< text.len:
            if text[i] == '/':
              return wmAbortToStarStar
        return wmMatch
      elif not matchSlash and patAt(p) == '/':
        # One asterisk followed by a slash: the star matches only within
        # the current directory, so jump straight to the next slash.
        var slash = -1
        for i in t ..< text.len:
          if text[i] == '/':
            slash = i
            break
        if slash < 0:
          return wmAbortAll
        t = slash
        # The slash itself is consumed by the loop increment below.
      else:
        while true:
          tch = txtAt(t)
          if tch == '\0':
            break
          # When the star is followed by a literal, skip ahead to each
          # occurrence of that literal instead of recursing per character.
          # A non-slash-crossing star must not look past the next '/'.
          if not isGlobSpecial(patAt(p)):
            var lit = patAt(p)
            if fold: lit = toLowerA(lit)
            while true:
              tch = txtAt(t)
              if tch == '\0' or (not matchSlash and tch == '/'):
                break
              if fold: tch = toLowerA(tch)
              if tch == lit:
                break
              inc t
            if tch != lit:
              return (if matchSlash: wmAbortAll else: wmAbortToStarStar)
          let matched = dowild(pattern, text, p, t, fold)
          if matched != wmNoMatch:
            if not matchSlash or matched != wmAbortToStarStar:
              return matched
          elif not matchSlash and txtAt(t) == '/':
            return wmAbortToStarStar
          inc t
        return wmAbortAll
    of '[':
      inc p
      var cch = patAt(p)
      var negated = false
      if cch == '!' or cch == '^':
        negated = true
        inc p
        cch = patAt(p)
      var prevCh = '\0'
      var matched = false
      while true:
        if cch == '\0':
          # Unterminated bracket expression aborts the whole match.
          return wmAbortAll
        if cch == '\\':
          inc p
          cch = patAt(p)
          if cch == '\0':
            return wmAbortAll
          if tch == cch:
            matched = true
        elif cch == '-' and prevCh != '\0' and
             patAt(p + 1) != '\0' and patAt(p + 1) != ']':
          inc p
          cch = patAt(p)
          if cch == '\\':
            inc p
            cch = patAt(p)
            if cch == '\0':
              return wmAbortAll
          if tch <= cch and tch >= prevCh:
            matched = true
          elif fold and isLowerA(tch):
            # Fold ranges by retrying with the uppercased text char
            # (tch itself was already lowercased).
            let tchUpper = toUpperA(tch)
            if tchUpper <= cch and tchUpper >= prevCh:
              matched = true
          cch = '\0'  # a range endpoint cannot start another range
        elif cch == '[' and patAt(p + 1) == ':':
          let s = p + 2
          p = s
          while patAt(p) != '\0' and patAt(p) != ']':
            inc p
          if patAt(p) == '\0':
            return wmAbortAll
          let n = p - s - 1
          if n < 0 or patAt(p - 1) != ':':
            # Didn't find ":]", so treat the '[' as a normal set member
            # and rescan from just after it.
            p = s - 2
            cch = '['
            if tch == cch:
              matched = true
          else:
            case pattern[s ..< s + n]
            of "alnum": (if isAlnumA(tch): matched = true)
            of "alpha": (if isAlphaA(tch): matched = true)
            of "blank": (if isBlankA(tch): matched = true)
            of "cntrl": (if isCntrlA(tch): matched = true)
            of "digit": (if isDigitA(tch): matched = true)
            of "graph": (if isGraphA(tch): matched = true)
            of "lower": (if isLowerA(tch): matched = true)
            of "print": (if isPrintA(tch): matched = true)
            of "punct": (if isPunctA(tch): matched = true)
            of "space": (if isSpaceA(tch): matched = true)
            of "upper":
              if isUpperA(tch): matched = true
              elif fold and isLowerA(tch): matched = true
            of "xdigit": (if isXdigitA(tch): matched = true)
            else: return wmAbortAll  # malformed [:class:] string
            cch = '\0'  # a class cannot serve as a range endpoint
        else:
          if tch == cch:
            matched = true
        prevCh = cch
        inc p
        cch = patAt(p)
        if cch == ']':
          break
      if matched == negated or tch == '/':
        return wmNoMatch
    else:
      if tch != pch:
        return wmNoMatch

    inc t
    inc p

  # Pattern exhausted: match only if the text is exhausted too.
  if t < text.len: wmNoMatch else: wmMatch

func wildmatch*(pattern, text: string; caseInsensitive = false): bool =
  ## Matches `text` (a `/`-separated relative path) against `pattern` using
  ## git's wildmatch semantics (always with `WM_PATHNAME`: wildcards never
  ## match `/`). `caseInsensitive` enables ASCII-only case folding
  ## (git's `WM_CASEFOLD`, i.e. `core.ignoreCase` behavior).
  dowild(pattern, text, 0, 0, caseInsensitive) == wmMatch
