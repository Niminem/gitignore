## `gitignore` — dependency-free, spec-compliant gitignore parser and
## pattern matcher. Public API: re-exports the layer modules.
##
## Layers 1–2 (`wildmatch`, `pattern`, `ignorefile`) are pure string
## processing. Layer 3 (`repo`) is the optional filesystem-backed ignore
## stack; import `gitignore/ignorefile` directly if you want to avoid it.

import gitignore/[wildmatch, pattern, ignorefile, repo]
export wildmatch, pattern, ignorefile, repo
