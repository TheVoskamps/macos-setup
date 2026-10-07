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

Never hand-edit this file — re-run `/repo-config`.
