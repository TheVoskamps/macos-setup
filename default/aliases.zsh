# default aliases — the universal base every machine gets.
#
# Keep this MINIMAL. Only truly universal shortcuts and helpers for
# tools the default tier itself installs belong here. Tool-specific
# aliases live with the profile that adopts the tool:
#   - git shortcuts / functions -> profiles/dev-core/aliases.zsh
#   - claude CLI wrappers (cr)   -> profiles/claude-code-aliases/aliases.zsh
# A machine that does no development never inherits the git alias soup.

# Bootstrap helpers (bat/fzf are installed by the core tier's Brewfile)
alias fsf='fzf'
alias cat='bat --paging=never'
# alias grep='rg'
# alias find='fd'

# ISO8601 timestamp (pure coreutils, universal)
alias 8601='date -u +"%Y-%m-%dT%H:%M:%SZ"'

# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Safety
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# My Usual
alias ll='ls -la'

# Smart cd and fzf helpers (fzf/zoxide/fd/bat install in the default
# tier's Brewfile)
alias cdz='z'     # jump to directories using zoxide
alias cdi='zi'    # interactive cd using zoxide + fzf
alias cdf='cd "$(fd -td -H . | fzf)"'   # cd into a subdir interactively
alias fh='history | fzf'                 # fuzzy search shell history
alias hist='history -10000 | sort -r | fzf'
alias fe='fzf --preview "bat --style=numbers --color=always {}"'  # preview files

alias reload='source ~/.zshrc'
alias restart='exec zsh -l'

# Shared helpers (m, ws, iterm_tab_count, set_title) live in
# shared/zsh/ and are sourced from ~/.zshrc via ~/.zsh-shared.
