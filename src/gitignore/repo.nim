## Repository ignore stack (Layer 3).
##
## Full cross-file gitignore semantics over a repository root, mirroring
## git's `prep_exclude` / `last_matching_pattern_from_lists` (dir.c):
##
## - Sources, lowest to highest precedence: the optional excludesFile,
##   `.git/info/exclude`, then `.gitignore` files from the repo root down
##   to the candidate's own directory — deeper wins. Within one source,
##   last match wins (Layer 2). Across sources, the highest-priority
##   source with any matching pattern decides.
## - Evaluation walks the candidate's directory prefixes shallowest-first.
##   Each prefix is tested against every source loaded so far; a *plain*
##   match decides the prefix ignored and is sticky across ALL sources:
##   the walk stops, the whole subtree is ignored, and deeper `.gitignore`
##   files are never even loaded — they are invisible and cannot
##   re-include anything. A *negated* match on a prefix is not sticky: it
##   overrides lower-priority plain matches for that prefix and the walk
##   continues deeper (so `docs/build/` in the root file plus `!build` in
##   `docs/.gitignore` leaves `docs/build/x` unignored).
## - Per-directory `.gitignore` files are lazy-loaded and cached, so the
##   walker does not re-read them for every entry.
##
## Config policy: the library stays dependency-free and neither parses
## gitconfig nor shells out to git. `.git/info/exclude` is read
## automatically when present. The excludesFile is an opt-in constructor
## parameter with NO default — a library must not silently read a global
## user file. git's own default is `core.excludesFile`, falling back to
## `$XDG_CONFIG_HOME/git/ignore` (i.e. `~/.config/git/ignore`); callers
## who want git's behavior resolve that themselves and pass it in.
## `caseInsensitive` is likewise a constructor parameter (mirrors
## `core.ignoreCase`).
##
## Index semantics: git never ignores tracked files; we do not read the
## index, so this module implements `git check-ignore --no-index`
## semantics. Symlinks get git's lstat view: a symlink is a file even
## when it points at a directory, and is never followed.
##
## Path handling: the API accepts OS paths (absolute under the repo root,
## or repo-root-relative with either separator); they are normalized to
## `/`-separated root-relative form before evaluation, and re-based to
## each ignore file's own directory via `IgnoreFile.basePath`. Yielded
## walker paths are root-relative with `/` separators.

import std/[algorithm, options, os, strutils, tables]
import ignorefile

export ignorefile

type
  NamedIgnoreFile = object
    source: string    ## ignore-file path as `git check-ignore -v` prints it
    file: IgnoreFile

  IgnoreStack* = object
    root: string      ## absolute repo root, `/` separators, no trailing `/`
    caseInsensitive: bool
    globals: seq[NamedIgnoreFile]
      ## lowest priority first: excludesFile (if given), .git/info/exclude
    dirCache: Table[string, NamedIgnoreFile]
      ## relDir -> parsed .gitignore of that dir (empty file when absent)

  RepoMatch* = object
    ## A repo-level `explain` result: the deciding pattern plus the ignore
    ## file it came from. `source`, `pattern.lineNo` and `pattern.original`
    ## are the three columns of `git check-ignore -v`.
    source*: string   ## ".gitignore", "a/.gitignore", ".git/info/exclude",
                      ## or the excludesFile path as passed to the constructor
    pattern*: Pattern

func sameRootStr(a, b: string): bool =
  # The repo-root prefix of an absolute input is compared with the FS's
  # case rules, not the matcher's `caseInsensitive` flag.
  when defined(windows): cmpIgnoreCase(a, b) == 0
  else: a == b

proc newIgnoreStack*(repoRoot: string; excludesFile = "";
                     caseInsensitive = false): IgnoreStack =
  ## Builds an ignore stack over `repoRoot`. `.git/info/exclude` is loaded
  ## if present. `excludesFile` ("" = none) is the caller's opt-in
  ## equivalent of `core.excludesFile`; a missing file is silently
  ## skipped, like git does. Ignore files found later on disk are read
  ## lazily, so build the stack after the tree is in place (or build a
  ## fresh one when ignore files change — there is no invalidation).
  result.root = absolutePath(repoRoot).replace('\\', '/')
  while result.root.len > 1 and result.root[^1] == '/':
    result.root.setLen(result.root.len - 1)
  result.caseInsensitive = caseInsensitive
  if excludesFile.len > 0 and fileExists(excludesFile):
    result.globals.add NamedIgnoreFile(
      source: excludesFile,
      file: parseIgnoreFile(readFile(excludesFile)))
  let info = result.root & "/.git/info/exclude"
  if fileExists(info):
    result.globals.add NamedIgnoreFile(
      source: ".git/info/exclude",
      file: parseIgnoreFile(readFile(info)))

proc toRel(s: IgnoreStack; path: string): string =
  ## Normalizes an OS path to the canonical root-relative form: `/`
  ## separators, no leading `./` or `/`, no trailing `/`. Raises
  ## `ValueError` for an absolute path outside the repo root.
  var p = path.replace('\\', '/')
  if p.isAbsolute:
    let under = p.len >= s.root.len and
                (p.len == s.root.len or p[s.root.len] == '/') and
                sameRootStr(p[0 ..< s.root.len], s.root)
    if not under:
      raise newException(ValueError,
        "path is not under the repo root (" & s.root & "): " & path)
    p = if p.len == s.root.len: "" else: p[s.root.len + 1 .. ^1]
  while p.startsWith("./"):
    p = p[2 .. ^1]
  while p.len > 0 and p[0] == '/':
    p = p[1 .. ^1]
  while p.len > 0 and p[^1] == '/':
    p.setLen(p.len - 1)
  if p == ".": "" else: p

func win32Aliased(relDir: string): bool =
  ## Win32 path resolution strips trailing spaces and dots from each
  ## component, so on Windows probing `ba./.gitignore` silently opens
  ## `ba/.gitignore` — a phantom ignore file for a directory that cannot
  ## exist under that exact name. Git reports no match for such paths
  ## (found by the Tier-3 fuzzer), so any prefix directory whose name
  ## Win32 would rewrite must be treated as having no ignore file.
  for comp in relDir.split('/'):
    if comp.len > 0 and comp[^1] in {' ', '.'}:
      return true
  false

proc gitignoreAt(s: var IgnoreStack; relDir: string): NamedIgnoreFile =
  ## The (cached) .gitignore of `relDir` ("" = repo root). A missing file
  ## caches as an empty IgnoreFile, which matches nothing.
  if relDir in s.dirCache:
    return s.dirCache[relDir]
  let source = if relDir.len == 0: ".gitignore"
               else: relDir & "/.gitignore"
  let onDisk = s.root & "/" & source
  let phantom = when defined(windows): win32Aliased(relDir) else: false
  let content = if not phantom and fileExists(onDisk): readFile(onDisk)
                else: ""
  result = NamedIgnoreFile(source: source,
                           file: parseIgnoreFile(content, basePath = relDir))
  s.dirCache[relDir] = result

func exactMatch(s: IgnoreStack; active: seq[NamedIgnoreFile];
                rel: string; isDir: bool): Option[RepoMatch] =
  ## Port of git's last_matching_pattern_from_lists over the sources
  ## loaded so far: highest-priority source first, last pattern first
  ## within a source. Matches `rel` itself only — the ancestor-prefix
  ## walk lives in `explain`, where it interleaves source loading.
  for k in countdown(active.high, 0):
    let base = active[k].file.basePath
    var sub: string
    if base.len == 0:
      sub = rel
    elif rel.len > base.len + 1 and rel[base.len] == '/' and
         rel.startsWith(base):
      sub = rel[base.len + 1 .. ^1]
    else:
      continue  # rel is not strictly below this file's directory
    for j in countdown(active[k].file.patterns.high, 0):
      if active[k].file.patterns[j].matches(sub, isDir, s.caseInsensitive):
        return some RepoMatch(source: active[k].source,
                              pattern: active[k].file.patterns[j])
  none(RepoMatch)

proc explain*(s: var IgnoreStack; path: string; isDir: bool):
    Option[RepoMatch] =
  ## Returns the pattern (and its source file) that decides `path`, or
  ## `none` when nothing matches — the `git check-ignore -v --no-index`
  ## columns. A negated result means the path is explicitly re-included.
  ## When an ancestor directory is ignored, the ancestor's deciding
  ## pattern is reported, exactly like git.
  let rel = s.toRel(path)
  if rel.len == 0:
    return none(RepoMatch)  # the repo root itself is never ignored
  var active = s.globals
  active.add s.gitignoreAt("")
  for i in 0 ..< rel.len:
    if rel[i] == '/':
      let prefix = rel[0 ..< i]
      let m = s.exactMatch(active, prefix, isDir = true)
      if m.isSome and not m.get.pattern.negated:
        return m  # plain-ignored prefix is sticky across all sources
      active.add s.gitignoreAt(prefix)
  s.exactMatch(active, rel, isDir)

proc isIgnored*(s: var IgnoreStack; path: string; isDir: bool): bool =
  ## Whether git (with `--no-index` semantics) would ignore `path`.
  ## `isDir` must be passed explicitly, like everywhere else in this
  ## library — the stack never stats the queried path itself.
  let m = s.explain(path, isDir)
  m.isSome and not m.get.pattern.negated

iterator walkNotIgnored*(s: var IgnoreStack; dir = ""): string =
  ## Recursively yields every not-ignored entry (files and directories)
  ## under `dir` (default: the repo root), as root-relative `/`-separated
  ## paths. Ignored directories are pruned — never descended into — and
  ## any entry named `.git` is always skipped. Each directory's entries
  ## come in lexicographic order; subdirectories are descended
  ## depth-first. Symlinks are yielded as files and never followed.
  var pending = @[s.toRel(dir)]
  while pending.len > 0:
    let d = pending.pop()
    let native = if d.len == 0: s.root else: s.root & "/" & d
    var entries: seq[tuple[name: string; isDir: bool]]
    for kind, name in walkDir(native, relative = true):
      if name == ".git":
        continue
      entries.add (name, kind == pcDir)
    entries.sort
    var subdirs: seq[string]
    for (name, isDirEntry) in entries:
      let rel = if d.len == 0: name else: d & "/" & name
      if not s.isIgnored(rel, isDirEntry):
        yield rel
        if isDirEntry:
          subdirs.add rel
    for i in countdown(subdirs.high, 0):
      pending.add subdirs[i]
