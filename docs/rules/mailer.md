# Mailer

## All mail goes out through `scripts/send_mail.sh`

A new sender pipes its message to `scripts/send_mail.sh` rather than
calling `msmtp`, and takes its From address from
`scripts/resolve_from.sh`.

## Code never writes the relay password to a file

Code that needs the relay password reads it from the login Keychain
entry named by `keychain_service` and `smtp_user`, and writes it
nowhere.

## A missing Keychain entry is a warning

`scripts/msmtp_setup.sh` warns about a missing Keychain entry rather
than failing the core tier, because the user may add the entry after
the tier runs.
