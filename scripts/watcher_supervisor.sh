#!/bin/bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs queue/inbox

ASHIGARU_COUNT=$(grep "^ashigaru_count:" config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "3")
if ! [[ "$ASHIGARU_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    ASHIGARU_COUNT=3
fi

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        return 0
    fi

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

while true; do
    pane_base=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

    start_watcher_if_missing "shogun" "shogun:main.0" "logs/inbox_watcher_shogun.log"
    start_watcher_if_missing "karo" "multiagent:agents.${pane_base}" "logs/inbox_watcher_karo.log"

    for i in $(seq 1 "$ASHIGARU_COUNT"); do
        pane=$((pane_base + i))
        start_watcher_if_missing "ashigaru${i}" "multiagent:agents.${pane}" "logs/inbox_watcher_ashigaru${i}.log"
    done

    sleep 5
done
