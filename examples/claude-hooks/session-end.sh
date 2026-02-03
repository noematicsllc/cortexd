#!/bin/bash
# Session end hook - spawn agent to save session summary to cortex

LOGFILE="/tmp/cortex-session-end.log"

# Prevent infinite recursion: skip if we ARE a cleanup agent
if [ "$CORTEX_CLEANUP_AGENT" = "1" ]; then
    echo "$(date): Skipping hook - this is a cleanup agent session" >> "$LOGFILE"
    exit 0
fi

# Read hook input from stdin
input=$(cat)
echo "$(date): Hook triggered" >> "$LOGFILE"
echo "Input: $input" >> "$LOGFILE"

transcript_path=$(echo "$input" | jq -r '.transcript_path')
reason=$(echo "$input" | jq -r '.reason // "unknown"')
echo "Transcript path: $transcript_path" >> "$LOGFILE"
echo "Reason: $reason" >> "$LOGFILE"

# Skip if no transcript
if [ -z "$transcript_path" ] || [ "$transcript_path" = "null" ]; then
    echo "No transcript, skipping" >> "$LOGFILE"
    exit 0
fi

# Derive project name from git repo (or fallback to directory name)
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$PWD")
echo "Project: $PROJECT" >> "$LOGFILE"

# Run agent with output captured to log
# CORTEX_CLEANUP_AGENT=1 prevents the spawned agent from triggering this hook again
echo "Spawning cleanup agent (reason: $reason)..." >> "$LOGFILE"
nohup bash -c "
    export CORTEX_CLEANUP_AGENT=1
    claude --max-turns 10 --dangerously-skip-permissions -p 'You are a session cleanup agent. Your job is to write an accurate handoff note for the next session.

CRITICAL: The handoff must reflect the FINAL state at session end, not carry forward stale info. Pay close attention to what the USER said - if they mentioned something was completed, merged, resolved, or changed, that OVERRIDES any previous context.

Steps:
1. Read the transcript at $transcript_path thoroughly
2. Note what the user explicitly stated (e.g., \"PR was merged\", \"that issue is fixed\", \"we decided X\")
3. Get current status: cortex get $PROJECT status-current
4. Write a NEW handoff that reflects reality at session end - do NOT copy forward outdated info from the old status

Update with: cortex put $PROJECT '\''{"id":"status-current","type":"status","updated":"'\''$(date +%Y-%m-%d)'\''","project_phase":"...","active_work":"...","handoff_note":"..."}'\''

The handoff_note should be 1-2 sentences: what was accomplished and what is the immediate next step (if any). If something was completed/merged/resolved, say so clearly.' >> \"$LOGFILE\" 2>&1
    echo 'Agent completed' >> \"$LOGFILE\"
" </dev/null >/dev/null 2>&1 &

disown

echo "Hook exiting, agent spawned in background" >> "$LOGFILE"
exit 0
