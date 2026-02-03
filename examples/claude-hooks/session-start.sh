#!/bin/bash
# Session start hook - inject cortex state into context

# Derive project name from git repo (or fallback to directory name)
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$PWD")

# Get current status
status=$(cortex get "$PROJECT" status-current 2>/dev/null)

if [ -n "$status" ]; then
    echo "## Cortex State (auto-injected)"
    echo ""
    echo "Current status from \`cortex get $PROJECT status-current\`:"
    echo '```json'
    echo "$status" | jq .
    echo '```'
fi
