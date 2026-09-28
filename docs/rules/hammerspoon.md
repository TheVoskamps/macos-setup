# Hammerspoon

## The relaunch is confirmed with a read-only probe

After `reload_hammerspoon` in `scripts/hammerspoon_setup.sh` falls back
to relaunching the app, it confirms the relaunch with `hs -c "true"`,
never a second `hs.reload()`: the relaunch already re-ran `init.lua`,
and the probe only checks that the IPC port came back up.

## The reload is testable without a live Hammerspoon

Every command the reload drives, and the retry timing
(`HS_RELAUNCH_INTERVAL`, `HS_RELAUNCH_TIMEOUT`), is overridable through
an environment variable, and sourcing the script instead of executing it
returns before the symlink work. A change to the reload keeps both.
