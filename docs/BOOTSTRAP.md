# Bootstrapping Alternatives

This doc collects other ways to bootstrap if you don't want to use the
main `bootstrap.sh` script.

This repo is **public**, so the default path needs no SSH key at all:
`bootstrap.sh` clones it over HTTPS (see the Quick Start in the README).
The SSH-based options below remain useful when you need to **push** to
this repo or clone a **private** repo. For the full 1Password SSH-agent
setup, see [1password-as-ssh-agent.md](1password-as-ssh-agent.md).

## A. Use 1Password SSH keys (AirDrop) and clone manually

1. AirDrop your keys to the new Mac:

   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh
   # Save these files:
   ~/.ssh/github_id_ed25519       # chmod 600
   ~/.ssh/github_id_ed25519.pub   # chmod 644
   ```

2. Add 1Password SSH agent to `~/.ssh/config`:

   ```text
   Host github.com
     IdentityAgent "~/.1password/agent.sock"
     AddKeysToAgent yes
     UseKeychain yes
   Host *.github.com
     IdentityAgent "~/.1password/agent.sock"
     AddKeysToAgent yes
     UseKeychain yes
   ```

3. Install Apple CLT, Homebrew, and mas as needed, then clone the
   repository and run `make install`.

## B. Generate a fresh SSH key

```bash
xcode-select --install
ssh-keygen -t ed25519 -C "evoskamp" -f ~/.ssh/github_id_ed25519
chmod 600 ~/.ssh/github_id_ed25519
chmod 644 ~/.ssh/github_id_ed25519.pub
# Copy the public key, then add it at GitHub → Settings → SSH and GPG keys
pbcopy < ~/.ssh/github_id_ed25519.pub
```

## C. HTTPS clone with a personal access token (PAT)

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
git clone https://github.com/evoskamp/macos-setup.git
# Use your GitHub username + PAT as the password at the prompt
```
