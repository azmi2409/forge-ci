# Agent skills

ForgeCI ships a skill for coding agents:
[`skills/forge-ci/SKILL.md`](../skills/forge-ci/SKILL.md). It tells an agent
how to write `.circleci/config.yml` for ForgeCI (supported features, absolute
paths, resource classes, test splitting), validate it, sign in with OAuth,
and discover, inspect, watch or cancel existing pipelines, including automatic
push/PR runs. It also covers fork-only runner pools, cache/credential isolation,
safe retries, and implementation-specific timeout behavior. Install it in each
repository that ForgeCI builds.

For PR #28's `runner-go` branch, Ruby remains the default; Go is opt-in with
`--implementation go`. The Rails control plane stays Ruby and switching only
the runner needs no DB migration. The skill directs operators to the
[Ruby-to-Go migration runbook](../DEPLOY.md#ruby-to-go-runner-migration): idle
non-deploy canary, one service per identity, unchanged trust pools, protected
tokens/backups, and preservation of every original installer flag and custom
env setting because reinstall rewrites env/unit files. Rollback must preserve
settings or restore the matching `.old` tree and env/unit `.bak` files together;
later installs replace these backups. No merged/deployed/completed-soak status
is implied. Go skips all remaining steps, including `on_fail`/`always`, after
timeout interruption; do not rely on those handlers for cleanup.

For automatic CI, the skill uses `forge-ci pipelines --project owner/repo
--sha SHA` to find the intended run, then `forge-ci status ID --wait` to watch
workflow/job transitions without starting duplicate work. It documents JSON
output, exit codes, exact SHA matching, empty-list troubleshooting and client/
server upgrade requirements. A missing run or unsupported command must not
cause an agent to trigger another deployment.

**Claude Code.** Install it as a project skill, so everyone working in the
repository gets it, and commit it:

```sh
gem install forge-ci                      # once, if the CLI isn't installed
forge-ci skill install                    # writes .claude/skills/forge-ci/SKILL.md
git add .claude/skills/forge-ci && git commit -m "Add the forge-ci agent skill"
```

- **Just for you, in every repository:** `forge-ci skill install --dir ~/.claude/skills`.
- **Without the gem installed:**

  ```sh
  mkdir -p .claude/skills/forge-ci
  curl -fsSL https://raw.githubusercontent.com/azmi2409/forge-ci/main/skills/forge-ci/SKILL.md \
    -o .claude/skills/forge-ci/SKILL.md
  ```

Claude loads it whenever a task touches the pipeline, or when you type
`/forge-ci`.

**Other agents** (Codex, Cursor, GitHub Copilot and anything else that reads
an instructions file): append the skill to that file.

```sh
forge-ci skill show >> AGENTS.md                         # Codex, and agents that read AGENTS.md
forge-ci skill show >> .github/copilot-instructions.md   # GitHub Copilot
```

**Make it yours.** The skill ends with a "Repository notes" section. Write
that repository's rules there: its resource classes, contexts, which job
deploys, and what an agent must not change without asking. Agents read them
with everything else. `forge-ci skill install --force` updates the skill but
replaces the file, so copy your notes back in afterwards.
