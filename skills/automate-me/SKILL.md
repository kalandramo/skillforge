---
name: "automate-me"
version: "1.0.0"
display_name: "个性化技能（Automate Me）"
description: "把用户的工作习惯与偏好提炼成一个专属 -mode 技能（例如 jay-mode），编排历史挖掘、技能创作与去 AI 味三步。当用户说「把我习惯固化下来」「做个我的工作模式」「automate me」「生成我的 mode」时使用。一次性的小偏好不值得这么做。"
user-invocable: true
---

# Automate me

A guided flow for turning the user's working conventions into a skill agents will follow. The output is one `-mode` skill tailored to them (e.g. `jay-mode`, `priya-mode`).

This skill orchestrates three others: an inline mining pass (see step 1), your harness's skill-authoring skill (authoring), and this repo's **writing** skill (the Unslop prose discipline). It sequences them. It doesn't replace them.

The skill-authoring skill is **skill-creator** in WorkBuddy and the bundled `$skill-creator` system skill in Codex. ZCode and Qoder have no equivalent, so follow the Agent Skills format at agentskills.io by hand. "`create-skill`" below means whichever of these you use.

## Flow

### 0. Check for an existing skill

Look recursively for `*-mode/SKILL.md` matching the user's handle in the host's skill folders. In the project: `.workbuddy/skills/`, `.zcode/skills/`, `.qoder/skills/`, `.agents/skills/`. For the user: `~/.workbuddy/skills/`, `~/.zcode/skills/`, `~/.qoder-cn/skills/` (`~/.qoder/skills/` for Qoder international), `~/.agents/skills/` (Codex). Mode skills can live in a personal category directory (`<skills>/<handle>/`), not only at the top level. If one exists, confirm intent with the host's structured-question tool (`AskUserQuestion` in WorkBuddy; `request_user_input` in Codex where enabled; ZCode and Qoder where available) unless they already said "update my skill" or similar:

- Update the existing skill (default for repeat runs)
- Start fresh (rare, ask why before doing it)

Update mode changes the rest of the flow:
- Step 1 mines only history since the skill was last edited (`git log -1 --format=%cI <path>`).
- Step 2 asks what's changed or missing, not what to capture from zero.
- Step 4 edits the existing file in place. Preserve sections the user hasn't contradicted. Revise ones with new evidence. Add new sections only for genuinely new rules.

### 1. Mine their history

Locate the active workspace's transcripts before fanning out. Use only that workspace's directory. Don't glob across every project's directory. That crosses workspace boundaries and reads private chats from unrelated projects. Where they live depends on the host:

- **WorkBuddy:** `~/.workbuddy/projects/<slug>/*.jsonl`, where `<slug>` is the workspace path with every character that isn't a letter or digit turned into "-".
- **Qoder:** `~/.qoder-cn/projects/<slug>/*.jsonl` (`~/.qoder/projects/<slug>/` for Qoder international), same `<slug>` rule.
- **Codex:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Codex files sessions by date, not by project, so scope by `session_meta.cwd` instead of by directory — `grep -l "\"cwd\":\"$PWD\"" "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl` — and read only the matches.
- **ZCode:** sessions live in a local database rather than per-project files, so there is no transcript to mine. Skip straight to asking the user in step 2 and say why.

Survey recent agent conversations within that scope for recurring patterns. Run multiple parallel subagents across slices of history (e.g. last 2-4 weeks, split into 3 slices so each has enough material). Model and effort come from the host. Each slice mining subagent reads transcripts from the workspace-scoped path the parent provides, looks for the signals below, and returns a short structured list of patterns it saw with evidence pointers. Default signals worth hunting:

- Response preferences (length, tone, format, "dumb it down" corrections)
- Delegation habits (subagents, models, specialized workflows, parallelism)
- Verification posture (what "done" means, unit tests vs live repro, reviewers)
- Code and prose discipline (style, principles cited, lint/format tools)
- Process conventions (worktrees, commits, PRs, review/merge tooling)
- Meta preferences (fixing skills mid-task, proposing new ones)

Cross-check across slices before elevating a signal. Patterns seen in 2+ slices are high-confidence. Lone signals are weak and usually get dropped.

### 2. Ask the user directly

Mining misses intent that hasn't come up yet. Use the host's structured-question tool (structured multi-choice: `AskUserQuestion` in WorkBuddy; `request_user_input` in Codex where enabled; ZCode and Qoder where available) rather than asking the user to type from scratch. If the host has none, ask in chat with numbered options.

Codex caps a structured question at 2-3 options with the recommended one first, so split the 4-6 options below into consecutive questions there rather than truncating the list.

Shape: one or two questions with 4-6 options each, multi-select for category questions. Start broad ("Which areas matter most?"), then follow up on selected areas with specific options. After the structured rounds, one free-form chat question catches anything the options missed.

Don't dump 20 questions.

### 3. Cluster findings

Group the combined signals into sections. Common ones (use only what applies):

- **Response style**: length, tone, format.
- **Autonomy**: how much to do without asking, MCP tool use.
- **Understand first**: which skills to reach for when scoping or investigating a change.
- **Subagents**: default, parallelism, model-to-task, specialized workflows.
- **Prose / code discipline**: principles, lint tools, style guides.
- **Review and verify**: repro posture, verification skills, live-testing tools.
- **Process**: git worktrees, commits, PRs, review/merge tooling.
- **Skills**: skill-authoring habits, fix-the-skill-first, proposing new skills.

A reference -mode skill (or your harness's model-config) shows the shape. Read it for granularity. Don't copy its content. The user's rules are not the same as anyone else's.

### 4. Draft the skill

Use your skill-authoring skill (`create-skill`) to author the skill. Placement:

- Path: preserve an existing mode skill's category. For a new mode, use `<skills>/<handle>/<handle>-mode/SKILL.md` when the repo has an established personal category for that handle. Otherwise default to `<skills>/<handle>-mode/SKILL.md` in the project, or the user-level skill folder if the user prefers a personal skill. `<skills>` is your harness's skill folder from step 0.
- Handle: the user's first name or chosen identifier.
- Frontmatter `description`: trigger on their name + `/<handle>-mode` + "work in their style", not on generic keywords like "write code" or "review PR".
- Frontmatter formatting: follow `create-skill`'s YAML rules. Keep `description` as one YAML scalar. Quote it or use `description: >-` with indented continuation lines when punctuation or wrapping requires it.
- Frontmatter `disable-model-invocation: true` by default. Opt out only if the user explicitly wants their mode to apply on every turn.

### 5. Iterate on prose

Apply this repo's **writing** skill (the Unslop discipline) and `create-skill`'s writing guidelines to every line.

Show the draft to the user and take feedback. Expect multiple iterations. Cut ruthlessly. A mode skill is not a manual.

### 6. Land it

Work in a worktree off main. Commit and open a PR. Don't push to main directly.

## Guardrails

- **Don't overfit to one conversation.** A preference stated once and contradicted another time is noise. Require multiple instances before codifying it.
- **Don't be clever.** Restating other skills' contents, inventing metaphors, or writing "poetic" prose for an agent reader is cost without benefit. Keep it operational.
- **Reference, don't inline.** Other skills the user relies on should appear as path references, not pasted excerpts. Same for any principle docs they maintain elsewhere.
- **Keep sections minimal.** Only add a section if the user has a specific, non-default rule there. "Communicate clearly" is not a section. "Short paragraphs. Tables when comparing options. Bullets only when items are genuinely parallel." is.
- **Name conventions generic.** Use "the user" or "the human" in imperatives, not the author's first name.
- **Don't force symmetry.** If a user has no process rules worth writing down, skip the Process section entirely.

## Evaluation

A `-mode` skill is subjective output. A `create-skill`-style test/iterate benchmark loop isn't useful here. Vibe-check with the user: does it read like them? Did it miss anything? Then ship.

Run a description-optimization loop only if the skill's trigger accuracy turns out to be a problem in practice.

## When not to use

- User wants a task-specific skill (not working conventions): `create-skill` alone, no mining required.
- User wants to capture one narrow workflow (e.g. "how I write commit messages"). That's a regular skill, not a mode skill.

