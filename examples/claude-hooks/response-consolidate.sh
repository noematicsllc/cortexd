#!/bin/bash
# Stop hook - consolidate learnings after agent response
# Spawns background agent to extract and store insights from the conversation turn

LOGFILE="/tmp/cortex-consolidate.log"
LOCKFILE="/tmp/cortex-consolidate.lock"

# Skip if we ARE a cortex helper agent
if [ "$CORTEX_HELPER_AGENT" = "1" ]; then
    exit 0
fi

# Read hook input
input=$(cat)
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')

echo "$(date): Stop hook triggered" >> "$LOGFILE"

# Skip if no transcript
if [ -z "$transcript_path" ] || [ "$transcript_path" = "null" ]; then
    echo "$(date): No transcript, skipping" >> "$LOGFILE"
    exit 0
fi

# Skip if consolidation already running (prevent pile-up during rapid exchanges)
if [ -f "$LOCKFILE" ]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -lt 120 ]; then  # Lock less than 2 minutes old
        echo "$(date): Consolidation already running (lock age: ${lock_age}s), skipping" >> "$LOGFILE"
        exit 0
    fi
    echo "$(date): Stale lock found (${lock_age}s), removing" >> "$LOGFILE"
    rm -f "$LOCKFILE"
fi

# Derive project name
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$PWD")

# Create lock before spawning
touch "$LOCKFILE"

# Spawn consolidation agent in background
echo "$(date): Spawning consolidation agent" >> "$LOGFILE"
nohup bash -c "
    export CORTEX_HELPER_AGENT=1
    claude --max-turns 8 --dangerously-skip-permissions -p 'You are a cortex consolidation agent. Review the latest exchange in the transcript and extract any valuable knowledge.

Transcript: $transcript_path

Read the LAST few messages (the most recent exchange). Look for:

1. LEARNINGS - Something non-obvious discovered or figured out
   Store as type:learning with fields: id, insight, topic, date

2. OUTCOMES - Work completed with results worth remembering
   Store as type:outcome with fields: id, task, domain, worked, failed, learned, date

3. INSIGHTS - Realizations or discoveries worth preserving
   Store as type:insight with fields: id, content, context, implications, date

4. PATTERNS - Procedural knowledge (how to do something)
   Store in public_memories as type:pattern with fields: id, name, description, steps or flow, date

Rules:
- Only store genuinely valuable knowledge, not routine exchanges
- Skip if the exchange was just Q&A or simple task execution with nothing novel
- Use cortex put $PROJECT for project-specific items
- Use cortex put public_memories for patterns/strategies that apply broadly
- Check if similar entry exists first: cortex query $PROJECT {\"type\":\"...\"}
- Use kebab-case ids, include date: $(date +%Y-%m-%d)

If nothing worth storing, exit without action.' >> '$LOGFILE' 2>&1
    echo \"\$(date): Consolidation agent completed\" >> '$LOGFILE'
    rm -f '$LOCKFILE'
" </dev/null >/dev/null 2>&1 &

disown

echo "$(date): Stop hook exiting, agent spawned" >> "$LOGFILE"
exit 0
