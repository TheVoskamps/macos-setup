# Configuring 1Password SSH Agent for Multiple GitHub Accounts on macOS

## Problem

You have multiple GitHub accounts (e.g., work and personal) and need the 1Password SSH agent to offer the correct SSH key for each. Both accounts connect to `github.com`, so SSH can't distinguish them by hostname alone.

## Prerequisites

- 1Password desktop app with SSH agent enabled
- All SSH keys stored in the **Private** vault (multiple `[[ssh-keys]]` sections referencing different vaults in `agent.toml` don't work reliably)
- 1Password Developer settings enabled

## Configuration

### 1. agent.toml

Location: `~/.config/1Password/ssh/agent.toml`

Keep it simple — reference only the Private vault. All SSH keys in that vault will be available to the agent.

```toml
[[ssh-keys]]
vault = "Private"
```

Verify keys are visible to the agent:

```bash
SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock ssh-add -l
```

### 2. Enable 1Password SSH Bookmarks Config Generation

1. Open 1Password → Settings → Developer.
2. Expand the **Advanced** section for the SSH Agent.
3. Enable **"Generate SSH config files from 1Password SSH bookmarks"**.

This causes 1Password to generate and manage `~/.ssh/1Password/config` along with `.pub` files named by key fingerprint. Do not manually edit any files in `~/.ssh/1Password/` — 1Password overwrites them.

### 3. Create a Bookmark on the SSH Key Item

In 1Password, find the SSH key item for the non-default GitHub account (the one that needs a specific host alias). Edit the item and add a custom field:

- **Type:** URL
- **Label:** SSH Bookmark (or similar)
- **Value:** `ssh://github-personal`

This tells 1Password to generate a `Match Host github-personal` block in `~/.ssh/1Password/config` that maps this host alias to this specific key with `IdentitiesOnly yes`.

### 4. ~/.ssh/config

The 1Password-generated config handles key selection. Your own config handles host alias resolution and the agent socket. Add the `Include` at the top.

```
Include ~/.ssh/1Password/config

Host github-personal
    HostName github.com
    User git

Host *
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

**Why both?** 1Password's `Match Host github-personal` block sets `IdentityFile` and `IdentitiesOnly` but does not define what `github-personal` resolves to. The `Host github-personal` block in your config provides `HostName github.com` so SSH knows where to connect. They are complementary.

### 5. Per-Repository Git Configuration

For the repo that uses the non-default account, set the remote to use the host alias and override the git identity:

```bash
git remote set-url origin git@github-personal:OrgOrUser/repo-name.git
git config --local user.email "personal@example.com"
git config --local user.name "Your Name"
```

All other repos continue using `git@github.com:...` as usual, which will use the default key offered by the agent.

### 6. Global Git Configuration

Set the default identity for all repos that don't have a local override:

```bash
git config --global user.email "work@example.com"
git config --global user.name "Your Name"
```

## What Doesn't Work

- **Multiple `[[ssh-keys]]` sections in agent.toml referencing different vaults** — keys from non-Private vaults didn't load reliably.
- **`IdentityFile` with a `.pub` file in `~/.ssh/config`** — macOS OpenSSH tries to parse the `.pub` file as a private key and fails with "invalid format".
- **`IdentityFile` without `.pub` extension (no corresponding private key on disk)** — macOS OpenSSH reports "no such identity" and does not fall back to the `.pub` file.

The 1Password bookmark-driven config generation is the supported path. It manages its own `.pub` files in a format that works with the agent.

## Verification

Test which GitHub account a host alias authenticates as:

```bash
ssh -T git@github-personal
```

GitHub responds with the username associated with the key, confirming the correct key was offered.
