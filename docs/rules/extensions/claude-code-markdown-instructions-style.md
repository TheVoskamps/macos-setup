# Claude Code Markdown Instructions Style — this repo

## For Authors

## For Authors and Checkers

### `CLAUDE.md` holds only the routing index

`CLAUDE.md` is a title followed by one entry per `.claude/rules/*.md`
and `docs/rules/*.md` file, and each such path appears in it exactly
once. Always-loaded content lives in `.claude/rules/`, on-demand content
in `docs/rules/`. A file under `docs/rules/extensions/` gets no entry,
because its own guide's lead reaches it.

### Every index entry carries a trigger and a one-sentence kernel

Each entry names the file's path, then the condition that should make a
reader load it, stated as a condition rather than a topic, then
`Kernel:` and exactly one sentence stating the file's hardest rule.

### No `.claude/rules/*.md` file carries `paths:` frontmatter

A `paths:` rule is withheld at launch and delivered only when the Read
tool opens a matching file, never when Bash reads it, so it cannot carry
content an agent must receive.

### `CLAUDE.md` and `.claude/rules/*.md` total at most 200 lines

`cat CLAUDE.md .claude/rules/*.md | wc -l` reports at most 200, because
every one of those files loads at launch for the main session and for
every subagent.
