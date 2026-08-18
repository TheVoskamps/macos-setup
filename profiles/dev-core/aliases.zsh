# dev-core aliases — git shortcuts, log variants, and helper functions.
#
# These live with the dev-core profile (not the default tier) so a
# machine that doesn't do development never gets the git alias soup.
# The git BINARY is installed in the default tier (bootstrap.sh needs
# it); dev-core re-asserts `git` in its own Brewfile as a
# development tool, alongside `gh`. Install is additive and idempotent,
# so the re-assertion is harmless.

# Git shortcuts - Helps (grep the alias table by family)
alias ghh='alias | grep "^g.h=" | grep -v "^ghh"'

# Git shortcuts - Status
alias gsh='alias | grep "^gs[a-z]*=" | grep -v "^gsh"'
alias gs='git status'
alias gss='git status -s'

# Git shortcuts - Diff
alias gdh='alias | grep "^gd[a-z]*=" | grep -v "^gdh"'
alias gd='git diff'
alias gds='git diff --stat'
alias gdcs='git diff --cached --stat'

# Git shortcuts - Add
alias gah='alias | grep "^ga[a-z]*=" | grep -v "^gah"'
alias ga='git add'
alias gaa='git add -A'

# Git shortcuts - Commit
alias gch='alias | grep "^gc[a-z]*=" | grep -v "^gch"'
alias gc='git commit -v'
alias gcm='git commit -v -m'
alias gce='git commit --allow-empty -m "Trigger pipelines with an empty commit" && git push'

# Git shortcuts - Push
alias gph='alias | grep "^gp[a-z]*=" | grep -v "^gph"'
alias gp='git push'

# Git shortcuts - Branch
alias gbh='alias | grep "^gb[a-z]*=" | grep -v "^gbh"'
alias gbv='git branch -v'
alias gbr='git branch -r -v'
alias gbl="git for-each-ref --sort=-committerdate refs/remotes/ --format='%(committerdate:iso) %(refname:short)'"
alias gbs='git switch'
alias grv='git remote get-url origin'

# aliases.zsh aggregates default + profiles + host (issue #150), so the
# default tier's `alias gbc='git switch -c'` is sourced before this
# file. zsh refuses to define a function whose name is an active alias
# ("defining function based on alias"), so drop the alias first. This is
# a no-op when the alias is absent.
unalias gbc 2>/dev/null
gbc() {
    if [[ -z "$1" ]]; then
        echo "Usage: gbc <new-branch-name>"
        return 1
    fi

    git switch -c "$1"
    git push -u origin "$1"
}

gbd() {
  if [[ -z "$1" ]]; then
    echo "Usage: gbd <branch-name>"
    return 1
  fi

  # Protect important branches (case-insensitive)
  local protected=(main integ release deploy)
  local branch_lower="${1:l}"  # zsh lowercase conversion

  if (( ${protected[(Ie)$branch_lower]} )); then
    echo "Error: Refusing to delete protected branch '$1'"
    return 1
  fi

  local deleted_local=0 deleted_remote=0

  if git branch -D "$1" 2>/dev/null; then
    deleted_local=1
  fi

  if git push origin --delete "$1" 2>/dev/null; then
    deleted_remote=1
  fi

  if (( deleted_local && deleted_remote )); then
    echo "Deleted '$1' locally and remotely"
  elif (( deleted_local )); then
    echo "Deleted '$1' locally (remote didn't exist)"
  elif (( deleted_remote )); then
    echo "Deleted '$1' remotely (local didn't exist)"
  else
    echo "Branch '$1' not found locally or remotely"
  fi
}

# Git shortcuts - Logs
alias glh='alias | grep "^gl[a-z]*=" | grep -v "^glh"'
# git log variants
# compact
# alias gl='git log --oneline --graph --decorate --pretty=format:"%C(yellow)%h%Creset %C(green)%s%Creset"'
alias gl='git log --oneline --graph --decorate --date=short --pretty=format:"%C(yellow)%h%Creset %C(white)%an%Creset %C(white)%ad%Creset %C(green)%s%Creset"'
alias glm='git log --graph --decorate'
# Recent activity (last 10)
alias gl10='git log --oneline --graph --decorate -10'
# Recent commits with dates
alias gld='git log --oneline --graph --decorate --date=short --pretty=format:"%C(yellow)%h%Creset %C(white)%an%Creset %C(white)%ad%Creset %C(green)%s%Creset"'
alias gldi='git log --oneline --graph --decorate --date=iso --pretty=format:"%C(yellow)%h%Creset %C(white)%an%Creset %C(white)%ad%Creset %C(green)%s%Creset"'
alias gld8601='git log --oneline --graph --decorate --date=iso8601-strict --pretty=format:"%C(yellow)%h%Creset %C(white)%an%Creset %C(white)%ad%Creset %C(green)%s%Creset"'
# With diffstat
alias gls='git log --oneline --graph --decorate --stat'
# Show changed files
alias glf='git log --oneline --graph --decorate --name-status'
# Search commits
alias glg='git log --oneline --graph --decorate --grep'
# Search for Author-specific
alias gla='git log --oneline --graph --decorate --author'
# show git log aliases
alias gll='alias | grep "git log"'

# combine git fetch && git diff --name-status && git diff --stat
# runs against remote, with a --fetch flag fetches remote refs first
gsr() {
  local update= remote branch
  if [ "$1" = "--fetch" ] || [ "$1" = "-f" ]; then
    shift; update=1
  fi
  remote="${1:-origin}"
  branch="${2:-$(git rev-parse --abbrev-ref HEAD)}"
  if [ -n "$update" ]; then
    git fetch -q "$remote" "$branch" || return 1
  else
    git fetch -q --refmap= "$remote" "$branch" || return 1
  fi
  python3 - "HEAD..FETCH_HEAD" <<'PYEOF'
import subprocess, sys, shutil
rng = sys.argv[1].split()
G, R, X = "\033[32m", "\033[31m", "\033[0m"
if not sys.stdout.isatty(): G = R = X = ""
WRAP_AT = 80

def z(extra):
    p = subprocess.run(["git","diff","-M","-z",*rng,*extra],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.stderr.write(p.stderr); sys.exit(p.returncode)
    return [t for t in p.stdout.split("\0") if t != ""]

smap, ns, i = {}, z(["--name-status"]), 0
while i < len(ns):
    s = ns[i]
    if s[:1] in ("R","C"): smap[ns[i+2]] = (s[0], ns[i+1]); i += 3
    else:                  smap[ns[i+1]] = (s[0], None);    i += 2

rows, nm, i = [], z(["--numstat"]), 0
while i < len(nm):
    add, dele, *rest = nm[i].split("\t")
    if rest and rest[0] == "": path = nm[i+2]; i += 3
    else:                      path = rest[0]; i += 1
    s, old = smap.get(path, ("?", None))
    disp = f"{old} -> {path}" if old else path
    rows.append((s, add, dele, disp))

binary = lambda v: v == "-"
tot = [(0 if binary(a) else int(a)) + (0 if binary(d) else int(d)) for _,a,d,_ in rows]
peak = max(tot) if tot else 0
SW   = max((len(r[0]) for r in rows), default=1)
dispw= max((len(r[3]) for r in rows), default=4)
W    = min(dispw, WRAP_AT)
cntw = max((len(str(t)) for t in tot), default=1)
term = shutil.get_terminal_size((100,20)).columns
graph_max = max(10, term - SW - 1 - W - 3 - cntw - 1)
scale = (graph_max/peak) if peak > graph_max else 1.0

def chunks(t, w): return [t[j:j+w] for j in range(0,len(t),w)] or [""]

for (s,a,d,disp), t in zip(rows, tot):
    if binary(a): bar, cnt = "Bin", "-"
    else:
        ai, di = int(a), int(d)
        pl, mi = round(ai*scale), round(di*scale)
        if (ai or di) and pl+mi == 0: pl = 1
        bar, cnt = f"{G}{'+'*pl}{X}{R}{'-'*mi}{X}", str(t)
    segs = chunks(disp, W); last = len(segs)-1
    for k, seg in enumerate(segs):
        pre = f"{s:<{SW}} " if k == 0 else " "*(SW+1)
        if k == last: print(f"{pre}{seg:<{W}} | {cnt:>{cntw}} {bar}")
        else:         print(f"{pre}{seg}")
PYEOF
}
