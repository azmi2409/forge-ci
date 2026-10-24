# Agent skills

ForgeCI ships a skill for coding agents:
[`skills/forge-ci/SKILL.md`](../skills/forge-ci/SKILL.md). It tells an agent
how to write `.circleci/config.yml` for ForgeCI (what's supported, absolute
paths, resource classes, test splitting), validate it before committing, and
start, watch and cancel pipelines. Install it in each repository that ForgeCI
builds.

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
