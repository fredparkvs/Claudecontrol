# Mission Centre — macOS

A bash port of the Windows PowerShell Mission Centre launcher. Runs in Terminal.app or iTerm2.

## Prerequisites

| Tool | Required | Install |
|---|---|---|
| `python3` | Yes | Pre-installed on macOS 12+ |
| `claude` CLI | Yes | https://claude.ai/code |
| `jig` | Recommended | https://github.com/jdforsythe/jig |
| `jq` | Optional | `brew install jq` (faster JSON parsing) |

## Setup

```bash
# 1. Clone or copy this folder anywhere on your Mac
# 2. Make the scripts executable (once)
chmod +x launch.sh mission-centre.sh

# 3. Run
bash launch.sh
```

On first run you'll be prompted for your **scan root** — the top-level folder
where your AI projects live (e.g. `/Users/you/AI`).

## Usage

```
╔════════════════════════════════════════════╗
║               MISSION CENTRE               ║
╚════════════════════════════════════════════╝

 [1]  My Web App [corporate]
      Firebase + React dashboard

──────────────────────────────────────────────

  [M]   New Meta Mission
  Pick a project number, [M] Meta Mission, [S] Scan, or [Q] Quit
```

- **Number** — open a project's launch menu
- **S** — scan for new projects under your scan root
- **M** — start a cross-project meta mission (`jig run build` from scan root)
- **Q** — quit

Inside a project:

- **L** — launch with the project's default Jig profile
- **J** — pick a Jig profile interactively
- **R1, R2…** — resume a recent Claude Code session
- **E** — open the project folder in Finder
- **B** — back

## Files

| File | Purpose |
|---|---|
| `mission-centre.sh` | Main script |
| `launch.sh` | Entry-point wrapper |
| `config.json` | Your scan root path *(gitignored — auto-created)* |
| `projects.json` | Your project registry *(gitignored — auto-created)* |
| `config.example.json` | Schema reference for config.json |
| `projects.example.json` | Schema reference for projects.json |

## How launchers work

Sessions and Jig profiles open in a **new Terminal.app window** via `osascript`.
If you prefer iTerm2, replace the `_open_terminal` function in `mission-centre.sh`:

```bash
_open_terminal() {
    local dir="$1" cmd="$2"
    osascript -e "tell application \"iTerm\" to create window with default profile command \"bash -c 'cd \\\"$dir\\\" && $cmd'\""
}
```

## Troubleshooting

**"jig is not in PATH"** — ensure jig is installed and your shell profile exports its location.

**Terminal window doesn't open** — macOS may prompt you to grant Terminal automation permissions the first time. Go to System Settings → Privacy & Security → Automation and allow Terminal.

**Sessions not showing** — Claude Code stores sessions in `~/.claude/projects/`. If you've never run a session in a project, no history will appear.

**Paths with spaces** — supported. The launcher quotes paths correctly for `osascript`.
