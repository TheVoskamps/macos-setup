# Mailer

## All mail goes out through `scripts/send_mail.sh`

A new sender pipes its message to `scripts/send_mail.sh` rather than
calling `msmtp`, and takes its From address from
`scripts/resolve_from.sh`.

## The relay password lives only in the login Keychain

No file in the repo or the host tier, `~/.msmtprc` included, ever holds
the password; msmtp reads it at send time through the `passwordeval`
line `scripts/msmtp_setup.sh` generates. Every place that names the
Keychain entry — generated config, `config.toml` comments, setup
messages, examples — names it by the same service (`keychain_service`)
and account (`smtp_user`).

## A missing Keychain entry is a warning

`scripts/msmtp_setup.sh` warns about a missing Keychain entry rather
than failing the core tier, because the user may add the entry after
the tier runs.
