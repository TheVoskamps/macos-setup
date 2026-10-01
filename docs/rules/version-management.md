# Version management

## The mise `.gitignore` block has one authoritative text

The heredoc in `scripts/asdf_to_mise.sh` is the block's authoritative
text. This repo's own `.gitignore` and the copy in
`docs/VERSION_MANAGEMENT.md` reproduce it verbatim, so a change to the
heredoc changes both copies in the same commit.
