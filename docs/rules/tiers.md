# Tier resolution

## Every config read goes through `scripts/config_common.sh`

A script sources the library and calls its readers rather than calling
`dasel` itself, because the readers assert the exactly-major-3 `dasel`
contract before their first read.

## A file's kind is declared in the library's kind table

`AGGREGATE_FILES` lists every file that concatenates across tiers
through `resolve_aggregate`. Every other file apart from `config.toml`
and the Brewfiles is single-winner and resolves through `resolve_file`
or `resolve_dir`. Changing a file's kind means editing that table, never
special-casing a caller.

## `config.toml` has three read paths

`resolve_config_value` reads the single-winner scalar sections. The
`profiles` array is read only through `get_profiles` and its variants.
A tier's `[profile]` section is read only through `read_post_install`
and `read_removals`, which never consult another tier.

## `host_tier_dir` is the only source of the host tier's path

A script that needs the host tier calls it rather than deriving the
path; the Makefile reaches it through `scripts/host_tier_dir.sh`.

## A profile-name diagnostic names the declaring `config.toml`

A new message about a profile name reads through
`read_raw_profiles_tagged` or a `*_tagged` reader built on it, so it can
print the `config.toml` path next to the name.
