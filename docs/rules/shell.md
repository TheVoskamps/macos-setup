# Shell

## A path into the repo goes through `~/.zsh-shared`, never `..`

`~/.zsh-shared` is a symlink to `<repo>/shared/zsh`, and anything that
must reach the current checkout without naming it — a generated
LaunchAgent plist, `m()` — goes through that symlink. What such a
caller runs is a committed entry inside `shared/zsh/`, as
`launchagent_runner` is, never `~/.zsh-shared/../<path>`: macOS
resolves `..` lexically against the symlink path, so that form lands
in `$HOME`, not in the repo.
