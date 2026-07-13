## Differential oracle harness (Tier 2, PLAN.md Milestones 4 + 5).
##
## For every corpus case (see `corpus.nim`):
##
## 1. Reset a temp git repo (`core.autocrlf false`, `core.ignorecase false`
##    are set explicitly so results don't depend on machine config).
## 2. Write the case's ignore files byte-exact (no newline translation):
##    the root `.gitignore`, any extra files (subdirectory `.gitignore`s,
##    `.git/info/exclude`), and — if the case has one — a
##    core.excludesFile, passed to git via `-c core.excludesfile=...`.
## 3. Materialize the case's paths on disk so git can tell files from
##    directories — `isDir` is an explicit input to our API, while
##    `git check-ignore` resolves it from the filesystem. Paths that cannot
##    exist on NTFS are queried as nonexistent (isDir = false only).
## 4. Run `git check-ignore -v --non-matching --no-index --stdin` over all
##    the case's paths in one batch (stdin joined with "\n" — never pipe
##    paths through PowerShell, which appends CRLF per line).
## 5. Compare git's verdict and all three `-v` columns (source file,
##    lineNo, pattern text) against the repo layer's `isIgnored`/`explain`
##    (an `IgnoreStack` built over the temp repo). Single-file cases are
##    additionally checked against Layer 2's `match`/`explain` directly.
##    Divergences are reported reproducibly and fail the run.
##
## Test-only code: std/osproc, temp dirs, and a system `git` are fine here;
## the library itself stays dependency-free.

import std/[options, os, osproc, strutils, streams, tempfiles]
import gitignore/repo
import corpus

# --------------------------------------------------------------- git plumbing

proc runGit*(repoDir: string; args: openArray[string];
             input = ""): tuple[output: string; code: int] =
  let p = startProcess("git", workingDir = repoDir, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  if input.len > 0:
    p.inputStream.write(input)
  p.inputStream.close()
  # Do NOT use outputStream.readAll here: it stops at the first read that
  # comes back smaller than its internal buffer, which on a pipe is just
  # "whatever the child had written so far" — git's output was silently
  # truncated to its first line. Only a zero-byte read means EOF.
  let outp = p.outputStream
  var buf: array[4096, char]
  while true:
    let n = outp.readData(addr buf[0], buf.len)
    if n <= 0:
      break
    let prev = result.output.len
    result.output.setLen(prev + n)
    copyMem(addr result.output[prev], addr buf[0], n)
  result.code = p.waitForExit()
  p.close()

proc gitOrDie(repoDir: string; args: openArray[string]) =
  let (output, code) = runGit(repoDir, args)
  if code != 0:
    quit("git " & args.join(" ") & " failed (" & $code & "):\n" & output)

proc setupRepo*(): string =
  result = createTempDir("gitignore_differential_", "")
  gitOrDie(result, ["init", "-q"])
  gitOrDie(result, ["config", "core.autocrlf", "false"])
  gitOrDie(result, ["config", "core.ignorecase", "false"])

proc resetWorktree(repoDir: string) =
  ## Removes everything except .git so cases can't contaminate each other.
  ## The files a case may write under .git (info/exclude, the excludes
  ## file) are reset explicitly since .git itself survives.
  for kind, path in walkDir(repoDir):
    if extractFilename(path) == ".git":
      continue
    if kind in {pcDir, pcLinkToDir}:
      removeDir(path)
    else:
      removeFile(path)
  createDir(repoDir / ".git" / "info")
  writeFile(repoDir / ".git" / "info" / "exclude", "")
  removeFile(repoDir / ".git" / "excludes-file")

proc materialize(repoDir: string; q: Query) =
  if not q.create:
    return
  let native = repoDir / q.path.replace("/", $DirSep)
  if q.isDir:
    createDir(native)
  else:
    createDir(native.parentDir)
    writeFile(native, "")

# ------------------------------------------------------ check-ignore parsing

type GitVerdict = object
  matched: bool
  source: string   ## first -v column, e.g. "a/.gitignore"
  lineNo: int
  pattern: string  ## as printed by -v: bang + pattern + slash

proc parseGitLine(line: string; sources: seq[string]): GitVerdict =
  ## `-v --non-matching` prints `source:lineNo:pattern<TAB>path` for matches
  ## and `::<TAB>path` for non-matches. Corpus paths contain no tabs, so the
  ## last tab separates the columns even if a pattern contains one. The
  ## source column is matched against the case's known ignore-file paths
  ## (longest first) rather than split on ':', because an absolute
  ## excludes-file path contains a drive colon on Windows.
  let tab = line.rfind('\t')
  doAssert tab >= 0, "unparseable check-ignore line: " & line.escape
  let left = line[0 ..< tab]
  if left == "::":
    return GitVerdict(matched: false)
  for src in sources:
    if left.len > src.len + 1 and left.startsWith(src) and
       left[src.len] == ':':
      let c2 = left.find(':', src.len + 1)
      doAssert c2 > src.len + 1,
        "unparseable check-ignore line: " & line.escape
      return GitVerdict(matched: true,
                        source: src,
                        lineNo: parseInt(left[src.len + 1 ..< c2]),
                        pattern: left[c2 + 1 .. ^1])
  doAssert false, "unexpected pattern source: " & line.escape

# ----------------------------------------------------- our side, canonicalized

func stripTrailingSpaces(s: string): string =
  ## Same rule as pattern.nim / git's trim_trailing_spaces(): a trailing run
  ## of unescaped spaces is removed (spaces only; a backslash escapes the
  ## next char; a lone trailing backslash disables trimming).
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

func canonical(original: string): string =
  ## Reduces a verbatim gitignore line to what `git check-ignore -v` prints
  ## in its pattern column: the line minus a trailing CR and minus unescaped
  ## trailing spaces (git reconstructs bang + pattern + trailing slash, which
  ## is exactly the trimmed line).
  var s = original
  if s.len > 0 and s[^1] == '\r':
    s.setLen(s.len - 1)
  stripTrailingSpaces(s)

# ------------------------------------------------------------------ the loop

proc describeOurs(verdict: MatchKind; expl: Option[Pattern]): string =
  result = $verdict
  if expl.isSome:
    result.add " via .gitignore:" & $expl.get.lineNo & ":" &
               canonical(expl.get.original).escape

proc describeRepo(m: Option[RepoMatch]): string =
  if m.isNone:
    "no match"
  else:
    m.get.source & ":" & $m.get.pattern.lineNo & ":" &
      canonical(m.get.pattern.original).escape

proc runCase*(repoDir: string; c: Case;
              failures, queries, gitMatches: var int) =
  resetWorktree(repoDir)
  if c.gitignore.len > 0:
    writeFile(repoDir / ".gitignore", c.gitignore)
  for (path, content) in c.files:
    let native = repoDir / path.replace("/", $DirSep)
    createDir(native.parentDir)
    writeFile(native, content)
  # The excludes file lives under .git so it is never itself a query
  # candidate. Configured and constructed with the same forward-slash
  # absolute path, so the -v source column compares byte-for-byte.
  var exclPath = ""
  var gitArgs = @["check-ignore", "-v", "--non-matching", "--no-index",
                  "--stdin"]
  if c.excludesFile.len > 0:
    exclPath = (repoDir / ".git" / "excludes-file").replace('\\', '/')
    writeFile(exclPath, c.excludesFile)
    gitArgs = @["-c", "core.excludesfile=" & exclPath] & gitArgs
  for q in c.queries:
    materialize(repoDir, q)

  var stdinBuf = ""
  for q in c.queries:
    stdinBuf.add q.path & "\n"
  let (output, code) = runGit(repoDir, gitArgs, input = stdinBuf)
  if code notin {0, 1}:
    quit("check-ignore failed in case '" & c.name & "' (" & $code & "):\n" &
         output)

  var lines = output.splitLines()
  while lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  doAssert lines.len == c.queries.len,
    "case '" & c.name & "': " & $c.queries.len & " queries but " &
    $lines.len & " output lines:\n" & output

  # Known sources, longest first, for unambiguous -v parsing.
  var sources = @[".gitignore"]
  for (path, _) in c.files:
    sources.add path
  if exclPath.len > 0:
    sources.add exclPath
  for i in 0 ..< sources.len:
    for j in i + 1 ..< sources.len:
      if sources[j].len > sources[i].len:
        swap(sources[i], sources[j])

  # Layer 2 is compared directly only for pure single-file cases; the
  # repo layer is compared for every case.
  let singleFile = c.files.len == 0 and c.excludesFile.len == 0
  let f = parseIgnoreFile(c.gitignore)
  var stack = newIgnoreStack(repoDir, excludesFile = exclPath)

  for i, q in c.queries:
    inc queries
    let git = parseGitLine(lines[i], sources)
    if git.matched:
      inc gitMatches
    var diverged = false
    var oursDesc = ""

    if singleFile:
      let verdict = f.match(q.path, q.isDir)
      let expl = f.explain(q.path, q.isDir)
      if not git.matched:
        diverged = verdict != mkUndecided or expl.isSome
      else:
        let expected =
          if git.pattern.startsWith("!"): mkIncluded else: mkIgnored
        diverged = verdict != expected or expl.isNone or
                   expl.get.lineNo != git.lineNo or
                   canonical(expl.get.original) != git.pattern
      if diverged:
        oursDesc = "layer2 " & describeOurs(verdict, expl)

    if not diverged:
      let m = stack.explain(q.path, q.isDir)
      let ignored = stack.isIgnored(q.path, q.isDir)
      if not git.matched:
        diverged = m.isSome or ignored
      else:
        diverged = m.isNone or
                   m.get.source != git.source or
                   m.get.pattern.lineNo != git.lineNo or
                   canonical(m.get.pattern.original) != git.pattern or
                   ignored == git.pattern.startsWith("!")
      if diverged:
        oursDesc = "repo " & describeRepo(m)

    if diverged:
      inc failures
      echo "DIVERGENCE in case: ", c.name
      echo "  .gitignore: ", c.gitignore.escape
      for (path, content) in c.files:
        echo "  ", path, ": ", content.escape
      if c.excludesFile.len > 0:
        echo "  excludesFile: ", c.excludesFile.escape
      echo "  path:       ", q.path.escape, "  isDir=", q.isDir,
           "  onDisk=", q.create
      echo "  git:        ", lines[i].escape
      echo "  ours:       ", oursDesc

when isMainModule:
  let repoDir = setupRepo()
  
  let (gitVersion, _) = runGit(repoDir, ["--version"])
  var failures = 0
  var queries = 0
  var gitMatches = 0
  for c in corpusCases:
    runCase(repoDir, c, failures, queries, gitMatches)
  try:
    removeDir(repoDir)
  except OSError:
    discard  # a stale temp dir is not worth failing the run over

  if failures > 0:
    echo failures, " divergence(s) across ", queries, " queries in ",
         corpusCases.len, " cases"
    quit(1)
  echo "OK: ", queries, " queries in ", corpusCases.len,
       " cases, zero divergences (", gitVersion.strip, ")"
