# Using 1Password as Your SSH Agent on macOS

This repo is **public**, so `bootstrap.sh` clones it over plain HTTPS and
needs no SSH key, no SSH agent, and no GitHub SSH authentication. The
1Password SSH-agent walkthrough that `bootstrap.sh` used to perform
inline has moved here, because the knowledge is still useful whenever you
*do* need SSH auth — pushing to this repo, cloning a private repo, or
authenticating to any other SSH host.

1Password can act as your SSH agent: it holds your private keys in an
encrypted vault and hands them to `ssh` on demand (gated by Touch ID /
your vault unlock), so the private key never sits unencrypted on disk.

> Juggling **multiple** GitHub accounts (e.g. work and personal) that
> both live on `github.com`? Start here for the base setup, then see
> [Configuring 1Password SSH Agent for Multiple GitHub Accounts on
> macOS](CONFIGURING_1PASSWORD_SSH_AGENT_FOR_MULTIPLE_GITHUB_ACCOUNTS_ON_MACOS.md)
> for the host-alias / bookmark layer on top.

## Prerequisites

- The 1Password 8 desktop app, installed and signed in. (Install it
  with `brew install --cask 1password`, or via the `01-security`
  Install category — `make security`.)
- An SSH key stored in 1Password's **Private** vault. 1Password can
  generate one for you (New Item → SSH Key) and, during creation, add
  the matching public key to your GitHub account.

## 1. Enable the 1Password SSH agent

1. Open **1Password → Settings → Developer**.
2. Enable **"Use the SSH agent"**.
3. Make sure your SSH key lives in the **Private** vault. (Multiple
   `[[ssh-keys]]` sections pointing at *different* vaults do not load
   reliably — keep all keys in `Private`.)

## 2. Point the agent at your vault (`agent.toml`)

Create the agent config so the agent offers keys from your Private
vault:

```bash
mkdir -p ~/.config/1Password/ssh
printf '[[ssh-keys]]\nvault = "Private"\n' > ~/.config/1Password/ssh/agent.toml
```

The resulting `~/.config/1Password/ssh/agent.toml`:

```toml
[[ssh-keys]]
vault = "Private"
```

## 3. Point `ssh` at the 1Password agent socket (`~/.ssh/config`)

Make sure `~/.ssh/config` contains the following (create the file if it
does not exist, mode `600`):

```text
Host *
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

This tells every `ssh` invocation to talk to the 1Password agent socket
instead of the default `ssh-agent`.

## 4. Verify the agent can see your key(s)

```bash
sock=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
SSH_AUTH_SOCK="$sock" ssh-add -l
```

You should see your key listed. Then confirm GitHub authentication:

```bash
ssh -T git@github.com
```

GitHub responds with the username associated with the key — e.g.
`Hi <username>! You've successfully authenticated...` — confirming the
correct key was offered.

## When you need this

- **Pushing** commits to this repo (HTTPS clone is read-only without a
  credential; SSH is the simplest write path).
- **Cloning private repos** that HTTPS-without-a-token can't reach.
- **Any other SSH host** (servers, other Git hosts) where you'd rather
  1Password hold the key than have it unencrypted on disk.

## See also

- [Configuring 1Password SSH Agent for Multiple GitHub Accounts on
  macOS](CONFIGURING_1PASSWORD_SSH_AGENT_FOR_MULTIPLE_GITHUB_ACCOUNTS_ON_MACOS.md)
  — the host-alias / bookmark layer for two-or-more accounts on
  `github.com`.
- [Bootstrapping Alternatives](BOOTSTRAP.md) — other ways to bootstrap
  (manual SSH-key clone, fresh key generation, HTTPS + PAT).
