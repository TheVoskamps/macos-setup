# Hammerspoon

## Reloading cannot rely on IPC alone

`hs -c "hs.reload()"` travels over IPC, and the IPC port comes up only
when `init.lua` runs `require("hs.ipc")`. When `init.lua` is broken or
has never loaded from the current checkout, the port is down, so
`reload_hammerspoon` in `scripts/hammerspoon_setup.sh` falls back to
relaunching the app. It confirms the relaunch with `hs -c "true"`,
never a second `hs.reload()`: the relaunch already re-ran `init.lua`,
and the probe only checks that the IPC port came back up.

## The reload is testable without a live Hammerspoon

Every command the reload drives, and the retry timing
(`HS_RELAUNCH_INTERVAL`, `HS_RELAUNCH_TIMEOUT`), is overridable through
an environment variable, and sourcing the script instead of executing it
returns before the symlink work. A change to the reload keeps both.
