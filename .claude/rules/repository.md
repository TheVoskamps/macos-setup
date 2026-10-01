# Repository

## This repo provisions macOS machines from layered tiers

Every tier contributes one unnumbered Homebrew `Brewfile` plus a
`[profile]` section in its `config.toml` declaring its `post_install`
commands and its `uninstall` / `purge` package lists. Tiers, lowest
priority to highest:

```text
default/                  the core tier, in repo
  < profiles/<name>/      each profile the host opts into, in list order
      < host tier         on local disk, outside the repo
```

A host opts into profiles through the `profiles` array of its host
tier's `config.toml`, lowest priority first.

## A change lands in the tier whose machines need it

A change every machine needs goes in `default/`, a change for one role
goes in that role's `profiles/<name>/`, and a change for one machine
belongs in that machine's host tier, which no commit carries. The repo
tracks only `default/`, `profiles/`, and `computer-specific/_template/`,
the template `make install` seeds an absent host tier from.

## A profile is a directory and nothing more

The Makefile discovers profiles by directory glob and each profile
declares its own hooks in its own `config.toml`, so adding or removing a
profile never takes a Makefile edit.

## Every operation stays idempotent

Re-running any target on an already-configured machine changes nothing,
and a change keeps it that way.

## A file under `.claude/` needs a `.gitignore` whitelist entry

`.claude/` is ignored except for the directories `.gitignore`
whitelists, so a file created anywhere else under it never reaches a
commit and never shows in `git status`.
