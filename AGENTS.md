<!-- agent-board:start -->
## Multi-agent work (agent-board)

Several coding agents (for example Claude Code and Codex) may work in this repo at the same time. They coordinate through a shared board driven by the `agent-board` CLI; its state lives in `.agent-board/` of the main checkout (untracked, shared by all worktrees).

When the human asks you to plan together with the other agent, to "work the board", to take a task, or to review the other agent's work: run `agent-board protocol` and follow it exactly. The short version: `agent-board whoami`, then `agent-board next`; claim a task before writing code; work on your own branch in your own worktree; submit it for review by the other agent; never edit board headers by hand. Create task branches/worktrees and commit only when the human explicitly permits these actions in chat. Mode defaults to manual; an agent may use `--human-approved` only after explicit chat authorization. See the installed agent-board skill's `USAGE.ru.md` for examples.
<!-- agent-board:end -->
