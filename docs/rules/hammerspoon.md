# Hammerspoon

## Reloading cannot rely on IPC alone

`hs -c "hs.reload()"` travels over IPC, and the IPC port comes up only
when `init.lua` runs `require("hs.ipc")`. When `init.lua` is broken or
has never loaded from the current checkout, the port is down, so
`reload_hammerspoon` in `scripts/hammerspoon_setup.sh` falls back to
relaunching the app, then confirms with the read-only probe
`hs -c "true"` rather than a second `hs.reload()`. When neither path
works, the run warns and exits non-zero rather than reporting success.

## The reload is testable without a live Hammerspoon

Every command the reload drives, and the retry timing
(`HS_RELAUNCH_INTERVAL`, `HS_RELAUNCH_TIMEOUT`), is overridable through
an environment variable, and sourcing the script instead of executing it
returns before the symlink work. A change to the reload keeps both.
