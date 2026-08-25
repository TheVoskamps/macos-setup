---
schema-version: 7
source-control: GitHub
issues: GitHub
issue-link-prefix: "#"
default-issue-source-branch: main
default-pr-target-branch: main
issue-branch-naming-prefix: none
---

github-project:
  project-id: PVT_kwDODgIBic4BW6zL
  fields:
    status:
      kind: single-select
      id: PVTSSF_lADODgIBic4BW6zLzhSLVSo
      default: Backlog
      options:
        Backlog: f75ad846
        Ready: 61e4505c
        In progress: 47fc9ee4
        In review: df73e18b
        Done: 98236657
    priority:
      kind: issue-field
      data-type: single-select
      field-id: IFSS_kgDOAjHxPg
      field-name: Priority
      default: Medium
      options:
        Urgent: IFSSO_kgDOA9dORg
        High: IFSSO_kgDOA9dORw
        Medium: IFSSO_kgDOA9dOSA
        Low: IFSSO_kgDOA9dOSQ
    size:
      kind: issue-field
      data-type: single-select
      field-id: IFSS_kgDOAjHxQQ
      field-name: Effort
      default: Medium
      options:
        High: IFSSO_kgDOA9dOSg
        Medium: IFSSO_kgDOA9dOSw
        Low: IFSSO_kgDOA9dOTA
  issue-types:
    default: Feature
    Task: IT_kwDODgIBic4BvGYy
    Bug: IT_kwDODgIBic4BvGYz
    Feature: IT_kwDODgIBic4BvGY0
    Tech Debt: IT_kwDODgIBic4CA7tN

# Repo Config

Read by `/issue-address` and by the `issue-developer`, `issue-fixer`,
`doc-updater`, and `pr-reviewer` subagents at the start of every run.
Do not assume values are already in context — re-read this file every
time.

## Fields

- **schema-version**: integer naming the file's schema version.
  The current version is `7`. The writer (`/repo-config`) stamps
  it into every file it produces; readers (see
  `skills/lib/repo-config.md`) consult it and abort cleanly when
  the value is missing or older than they require. Do not edit
  this by hand — re-run `/repo-config` to migrate to a newer
  version.
- **source-control**: `GitHub` or `CodeCommit`. Selects between `gh`
  and `aws codecommit` for VCS operations.
- **issues**: `GitHub` or `Jira`. Selects between `gh issue` and the
  Jira CLI/API for issue operations.
- **issue-link-prefix**: prefix used when referencing an issue in
  commit messages and PR bodies. The orchestrator and agents
  substitute it as a literal string concat: `<issue-link-prefix><N>`.
  For GitHub repos, set this to `#` so references render as `#123`.
  For Jira, use the project key plus dash, e.g. `SET-` (references
  like `SET-123`).
- **default-issue-source-branch**: branch that new issue work
  branches FROM. The orchestrator must pin this when creating the
  feature branch (e.g.
  `git switch -c <name> origin/<source-branch>`) so the branch is
  rooted at the right commit, not at whatever HEAD the worktree
  happened to start on.
- **default-pr-target-branch**: branch that issue PRs target. Often
  the same as `default-issue-source-branch`, but not always.
- **issue-branch-naming-prefix**: branch naming style.
  - `none`     -> `issue-917-slug`
  - `initials` -> `ev/issue-917-slug`
  - `name`     -> `edwin/issue-917-slug`

## Optional: `github-project:` block

This section is **body-only**; it is not part of the seven-key
front-matter. Add it below the front-matter when the repo has an
associated GitHub Project V2 board and you want the `/issue-*`
commands (and `/issue-create`'s `--type` / `--priority` / `--size`
/ `--status` flags in particular) to resolve human-readable names to
the project's field IDs and option IDs.

Repos without a project board **omit this block entirely**. The
`/issue-*` commands degrade gracefully: project-specific flags emit a
one-line warning and skip, while non-project operations work
normally.

Schema:

```yaml
github-project:
  project-id: PVT_kwDO...     # ProjectV2 node ID
  fields:
    status:
      kind: single-select
      id: PVTSSF_lADO...      # single-select field ID
      default: Backlog
      options:
        Backlog:     <option-id>
        Todo:        <option-id>
        In Progress: <option-id>
        In review:   <option-id>
        Done:        <option-id>
    priority:
      kind: number
      id: PVTF_lADO...        # number-field ID
      default: 3
      min: 1
      max: 9
    size:
      kind: label
      namespace: "size:"
      default: M
      options: [XS, S, M, L, XL]
  issue-types:
    default: Feature
    Bug:     IT_kwDO...
    Feature: IT_kwDO...
    Goal:    IT_kwDO...
    Problem: IT_kwDO...
```

The `priority` block's `min: 1` / `max: 9` values above are
illustrative — the wizard prompts the user for those and does not
auto-fill them.

Keys:

- **project-id**: the ProjectV2 node ID (starts with `PVT_`). Find
  with `gh project list --owner <org>` and convert the project
  number to a node ID via GraphQL.
- **fields.\<slot\>.kind**: required discriminator on every populated
  slot. One of `number`, `single-select`, `issue-field`, `label`, or
  `skip`. The remaining keys on the slot depend on the kind; see the
  "Field kinds" section of `skills/lib/issue.md` for the per-kind
  schema and examples. There is no implicit default and no
  backwards-compat shim for the old `type:` shape — a repo on the old
  shape is invalid and must be regenerated by re-running
  `/repo-config`.
- **fields.\<slot\>.id**: for `kind: number` and `kind: single-select`,
  the project field node ID (`PVTF_...` for number fields,
  `PVTSSF_...` for single-select). Find with
  `gh project field-list <project-number> --owner <org>`. Not used
  by `kind: label` (the label name is the identifier),
  `kind: issue-field` (which uses `field-id` instead), or
  `kind: skip`.
- **fields.\<issue-field-slot\>.field-id / .field-name / .data-type**:
  for `kind: issue-field`, the native GitHub Issue Field's node ID
  (`field-id`, `IFSS_...`), its human-readable name (`field-name`,
  for display and error messages), and its data-type
  (`data-type: single-select` — the only data-type supported today).
  `options:` maps option names to native-field option IDs
  (`IFSSO_...`). Unlike the project-field kinds, an `issue-field` slot
  reads and writes the value on the issue itself, so it works
  regardless of project-board membership.
- **fields.\*.default**: optional per-slot default. Resolution order
  for `/issue-create`'s slot flags (`--priority`, `--size`,
  `--status`) is: CLI flag > interactive prompt > this repo-config
  default > slot-skip. The interactive prompt rung shows the user
  the slot's options with this `default:` as the recommended /
  first option (or, for `--size`, the model's read of the issue
  body — see `skills/lib/issue.md` "Interactive prompt rung" and
  the "Size evaluation heuristic" in
  `skills/issue-create/SKILL.md`). Set-slot verbs
  (`/issue-set-priority`, `/issue-set-size`, `/issue-set-status`)
  do not consult this `default:` — they require an explicit
  `<value>` positional argument. Slot flags have no built-in
  default — if none of CLI flag, interactive prompt, or this
  `default:` produces a value, the slot is skipped per "Graceful
  degradation" in `skills/lib/issue.md`. The non-slot built-in
  defaults (`--type` = `Feature`, `--assignee` = current GitHub user,
  `--labels` = none, `--parent` = none) still apply to their
  respective flags.
- **fields.\<number-slot\>.min / .max**: bounds on a `kind: number`
  slot. Out-of-range values abort the verb cleanly rather than
  writing nonsense to the board.
- **fields.\<single-select-slot\>.options**: the human-readable option
  names mapped to their option IDs. The setter verb does a
  case-insensitive match against this map; canonical capitalization
  for display comes from the keys.
- **fields.\<label-slot\>.namespace / .options**: the label namespace
  (e.g. `"size:"`) and a flat list of option suffixes. Concrete
  labels are `<namespace><option>` (e.g. `size:XS`). The verb
  manages the slot via `gh issue edit --add-label/--remove-label`.
- **issue-types**: the human-readable issue-type names mapped to
  their type IDs (`IT_...`). `default:` selects which type
  `/issue-create` uses when `--type` is not passed.

The `/repo-config` skill auto-discovers and populates this block
interactively: pick the project from `gh project list`, then for each
conceptually-standard slot (`status`, `priority`, `size`) the wizard
offers every enumerated project field plus a label-namespace option
and a skip option, and writes `kind:` on every populated slot.
Issue-types are pulled separately via GraphQL. Hand-editing is
supported, but `/repo-config` is a full-rewrite tool: re-running it
replaces this entire file with content built from your answers in
that run. It does recommend the existing file's current values as the
default for each interview question, so an accept-everything re-run
reproduces the recognized fields — but any hand-edited content the
wizard does not interview for (e.g. a custom slot it doesn't know
about, or prose you added to the body) is dropped. To keep such hand
edits, decline the overwrite prompt at the start of the next run. See
`skills/lib/issue.md` for full details on how the block is consumed.

## Optional: `jira:` block

This section is the Jira analogue of `github-project:`. It is
**body-only**, appears only under `issues: Jira` (mutually exclusive
with `github-project:`), and lets the `/issue-*` commands resolve
human-readable metadata names to the identifiers `acli` uses. Where
GitHub addresses everything by opaque node IDs, `acli` addresses most
Jira things by **name**, so most `jira:` maps are name→name (identity
maps that pin the canonical spelling and the closed option set); only
custom-field slots carry an opaque `field-id:`.

Schema:

```yaml
jira:
  project-key: SET            # Jira project key (basis of issue-link-prefix)
  fields:
    status:
      kind: status            # transition by target status name
      default: Backlog
      options:
        Backlog:     Backlog
        In Progress: In Progress
        Done:        Done
    priority:
      kind: custom-field      # Jira custom field (customfield_NNNNN)
      field-id: customfield_10031
      default: Medium
      options:
        Low:    Low
        Medium: Medium
        High:   High
    size:
      kind: label             # label namespace (same as the GitHub label kind)
      namespace: "size:"
      default: M
      options: [XS, S, M, L, XL]
  issue-types:
    default: Task
    Task:  Task
    Bug:   Bug
    Story: Story
```

The Jira kinds are `status` (workflow status, written via a Jira
transition), `custom-field` (a Jira custom field with a `field-id:`),
`label` (a label namespace, identical to the GitHub `kind: label`),
and `skip`. See `skills/lib/jira.md` for the full `acli` command
templates (auth, discovery, application) and the
`skills/lib/repo-config.md` "`jira:` block" section for the read
contract.

Repos using Jira without metadata tracking **omit this block
entirely** (or carry a skip marker); the `/issue-*` commands degrade
gracefully the same way they do for an absent `github-project:` block.

The `/issue-*` Jira **operations** that consume this block are
implemented (issue #9, built on the #249 foundation): they live in
the "Jira backend" section of `skills/lib/issue.md` and call `acli`
per `skills/lib/jira.md`. A Jira repo without this block (or with a
skip marker) still degrades gracefully — metadata-requiring
operations warn-and-skip rather than aborting the run.

## Why this file exists

Different repos use different VCS, issue trackers, and branching
strategies. The `/issue-address` orchestrator and its subagents
(`issue-developer`, `issue-fixer`, `doc-updater`, `pr-reviewer`)
must not hardcode assumptions like "PR base is `main`", "use `gh`",
or "issue link is `#NNN`". When a repo deviates, the orchestrator
silently does the wrong thing. This file is the single source of
truth that everything reads at the start of every run.

If this file is missing, `/issue-address` aborts with an error
pointing at this skill (`/repo-config`) to create one
interactively.
