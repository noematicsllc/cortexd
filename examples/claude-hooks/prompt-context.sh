#!/bin/bash
# Prompt submit hook - retrieve relevant cortex context and capture corrections/decisions
# Spawns agents to do cortex work so main agent doesn't need to be cortex-aware

LOGFILE="/tmp/cortex-prompt-context.log"

# Skip if we ARE a cortex helper agent
if [ "$CORTEX_HELPER_AGENT" = "1" ]; then
    exit 0
fi

# Read hook input
input=$(cat)
prompt=$(echo "$input" | jq -r '.prompt // ""')

# Skip empty prompts
if [ -z "$prompt" ]; then
    exit 0
fi

echo "$(date): Prompt received (${#prompt} chars)" >> "$LOGFILE"

# Derive project name
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$PWD")

# --- CAPTURE PHASE ---
# Detect corrections and decisions in user's message, spawn agent to extract and store
# Patterns: "actually", "no,", "not quite", "the real issue", "let's go with", "decided to", "we'll use"

capture_patterns='actually|no,|not quite|the real issue|let'"'"'s go with|decided to|we'"'"'ll use|I meant|to clarify'

if echo "$prompt" | grep -qiE "$capture_patterns"; then
    echo "$(date): Capture pattern detected, spawning capture agent" >> "$LOGFILE"

    # Spawn capture agent in background (don't block the prompt)
    nohup bash -c "
        export CORTEX_HELPER_AGENT=1
        claude --max-turns 5 --dangerously-skip-permissions -p 'You are a cortex capture agent. Extract and store important knowledge from this user message:

---
$prompt
---

Determine if this contains:
1. A CORRECTION (user correcting misunderstanding) - store as type:correction with fields: context, wrong_understanding, correct_understanding, insight
2. A DECISION (choosing between alternatives) - store as type:decision with fields: context, outcome, reasoning

If neither, exit without storing anything.

Use: cortex put $PROJECT with appropriate JSON including id (kebab-case), type, date ($(date +%Y-%m-%d)), and relevant fields.

Be selective - only store genuinely useful knowledge, not routine conversation.' >> '$LOGFILE' 2>&1
    " </dev/null >/dev/null 2>&1 &
    disown
fi

# --- RETRIEVAL PHASE ---
# Query cortex for context relevant to this prompt, inject into conversation

# Extract key terms (simple approach: words > 4 chars, not common words)
keywords=$(echo "$prompt" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]{5,}\b' | sort -u | head -5)
echo "$(date): Keywords: $keywords" >> "$LOGFILE"

# Build context from cortex queries
context=""

# Check for relevant decisions
decisions=$(cortex query "$PROJECT" '{"type":"decision"}' 2>/dev/null | jq -c '.[]' 2>/dev/null | head -3)
if [ -n "$decisions" ] && [ "$decisions" != "null" ]; then
    # Filter decisions that might be relevant (simple keyword match)
    relevant_decisions=""
    while IFS= read -r decision; do
        for kw in $keywords; do
            if echo "$decision" | grep -qi "$kw"; then
                relevant_decisions="$relevant_decisions$decision"$'\n'
                break
            fi
        done
    done <<< "$decisions"

    if [ -n "$relevant_decisions" ]; then
        context="${context}## Relevant Past Decisions\n$relevant_decisions\n"
    fi
fi

# Check for relevant corrections
corrections=$(cortex query "$PROJECT" '{"type":"correction"}' 2>/dev/null | jq -c '.[]' 2>/dev/null | head -3)
if [ -n "$corrections" ] && [ "$corrections" != "null" ]; then
    relevant_corrections=""
    while IFS= read -r correction; do
        for kw in $keywords; do
            if echo "$correction" | grep -qi "$kw"; then
                relevant_corrections="$relevant_corrections$correction"$'\n'
                break
            fi
        done
    done <<< "$corrections"

    if [ -n "$relevant_corrections" ]; then
        context="${context}## Relevant Corrections\n$relevant_corrections\n"
    fi
fi

# Check for relevant patterns
patterns=$(cortex query public_memories '{"type":"pattern"}' 2>/dev/null | jq -c '.[]' 2>/dev/null | head -3)
if [ -n "$patterns" ] && [ "$patterns" != "null" ]; then
    relevant_patterns=""
    while IFS= read -r pattern; do
        for kw in $keywords; do
            if echo "$pattern" | grep -qi "$kw"; then
                relevant_patterns="$relevant_patterns$pattern"$'\n'
                break
            fi
        done
    done <<< "$patterns"

    if [ -n "$relevant_patterns" ]; then
        context="${context}## Relevant Patterns\n$relevant_patterns\n"
    fi
fi

# Output context if we found anything relevant
if [ -n "$context" ]; then
    echo "$(date): Injecting context" >> "$LOGFILE"
    # Escape for JSON
    escaped_context=$(echo -e "$context" | jq -Rs .)
    echo "{\"hookSpecificOutput\": {\"hookEventName\": \"UserPromptSubmit\", \"additionalContext\": $escaped_context}}"
fi

exit 0
