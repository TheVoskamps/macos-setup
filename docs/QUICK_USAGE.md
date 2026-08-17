# Quick Usage

## Install

```bash
make install                    # every tier this host opts into, in order
make core                       # the core tier only
make profiles                   # what profiles exist; * marks this host's
make profile web                # one profile
make profile dev-core aws       # several, in the order given
```

## Update Everything

```bash
make update
```

## Pull Latest from main

```bash
make self-update            # auto-stash if dirty, switch from non-main, ff-pull
make self-update DRY_RUN=1  # rehearse without making changes
```

## Tool Versions

```bash
make versions-install      # install what the resolved mise config declares
make versions-outdated     # what has a newer version available
make versions-update       # install latest and bump the config
mise ls --current          # what is active here, and which file set it
```
