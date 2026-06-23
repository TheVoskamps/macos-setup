# Quick Usage

## Install by Category

```bash
make core
make security
make dev
make desktop
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

## asdf Plugins and Versions

```bash
make plugins
asdf install
asdf current
```
