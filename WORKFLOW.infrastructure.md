---
tracker:
  kind: github
  provider:
    repo: cptkadm/symphony
    token: $GITHUB_TOKEN
  required_labels:
    - symphony
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 5000
workspace:
  root: ~/Developer/symphony-workspaces/infrastructure
hooks:
  after_create: |
    git clone --depth 1 https://github.com/cptkadm/symphony.git .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    writableRoots: []
    networkAccess: true
    excludeTmpdirEnvVar: false
    excludeSlashTmp: false
---
You are autonomously working on Symphony infrastructure issue {{ issue.identifier }}.

Title:
{{ issue.title }}

Description:
{{ issue.description }}

This repository is the development control plane used to build other software. Treat changes here as high assurance.

## Establish the delta

Before editing:

1. Inspect concise Git/workspace state and determine whether this issue already has an open PR.
2. Read the relevant portions of `README.md`, `SPEC.md`, `elixir/README.md`, directly affected implementation, and focused tests. Do not dump unrelated repository content into context.
3. If an existing PR exists, inspect its current diff and newest unresolved review/CI feedback first and continue that PR rather than creating replacement work.
4. Reproduce the reported behavior or establish a deterministic failing signal before changing code whenever practical.

## Safety invariants

- Work only in the assigned issue workspace.
- One issue attempt owns one workspace and one implementation branch.
- Do not weaken sandboxing, credential isolation, merge guards, workspace isolation, or tracker scoping merely to make a test pass.
- Never place tokens or credentials in repository files, comments, logs, or child-process environment variables beyond the existing host-side authority model.
- Do not merge your own pull request.
- If an unresolved change would materially broaden agent authority, expose credentials, weaken isolation, create destructive external behavior, or alter merge policy beyond the issue's explicit contract, stop and report the exact authority decision required.
- Prefer narrow, mechanically enforceable invariants over prose-only safety rules.

## Git mutations

Codex may inspect Git state with read-only commands. For Git mutations use the client-side `workspace_git` tool only:

- `ensure_branch` to create or switch to the issue/PR branch;
- `commit` with explicit repository-relative paths;
- `push` to push the current non-default branch.

Do not use shell-based `git switch`, `git checkout`, `git add`, `git commit`, `git push`, force push, alternate clones, or temporary repositories as a fallback. If `workspace_git` is unavailable or fails, report the exact blocker on the issue and stop.

## Execution

Work autonomously through discovery, implementation, focused verification, failure diagnosis, and correction. Keep scope tied to the issue. Do not introduce speculative frameworks or provider abstractions unless the issue requires them.

For changes to orchestration behavior, add regression tests for negative/failure paths and race conditions, not only the happy path. Prefer deterministic clocks, fake provider/App Server boundaries, and true multi-process tests where concurrency behavior is the subject.

## Verification

Before handoff:

- inspect the final diff;
- run focused tests for changed behavior;
- run `cd elixir && make all`;
- run `git diff --check`;
- verify failure behavior and regression coverage;
- confirm no generated secrets, local paths, or unrelated changes are present.

If an open PR already exists, continue its head branch, commit/push the verified delta, and update the issue/PR with concise evidence. Do not create a replacement PR and do not merge it.

If no PR exists:

- create one task-specific branch with `workspace_git`;
- commit and push the scoped change;
- create a PR against `main` using `github_api`;
- PR body must contain `Closes #<issue number>`, a concise summary, verification evidence, and explicit residual risk if any;
- comment on the originating issue with the PR URL;
- remove the `symphony` label only after the PR is successfully created.

This workflow intentionally stops at a verified PR. Control-plane changes require independent/high-assurance review before merge.