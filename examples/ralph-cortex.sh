#!/bin/bash
# ralph-cortex.sh - Ralph (iterative PRD execution) with cortex memory
#
# Usage: ./ralph-cortex.sh <project-name> [max-iterations]
#
# This script runs Claude Code in a loop to complete PRD items,
# using cortex to persist state, failures, and learnings across iterations.
#
# Setup:
#   1. Create the project table and add PRD items:
#      cortex create ralph_myproject id type
#      cortex put ralph_myproject '{"id":"prd-1","type":"prd_item","description":"Add auth","status":"pending","priority":1}'
#
#   2. Run the loop:
#      ./ralph-cortex.sh myproject
#
# The agent will receive context about past failures and learnings,
# preventing repeated mistakes across iterations.

set -e

PROJECT="$1"
TABLE="ralph_${PROJECT}"
MAX_ITERATIONS="${2:-20}"

if [ -z "$PROJECT" ]; then
    echo "Usage: $0 <project-name> [max-iterations]"
    exit 1
fi

# Ensure table exists
cortex create "$TABLE" id type 2>/dev/null || true

# Check for state or PRD items
if ! cortex get "$TABLE" state >/dev/null 2>&1; then
    ITEMS=$(cortex query "$TABLE" '{"type":"prd_item"}' 2>/dev/null | jq 'length')
    if [ "$ITEMS" -eq 0 ] 2>/dev/null; then
        echo "No state or PRD items found. Initialize first:"
        echo "  cortex put $TABLE '{\"id\":\"prd-1\",\"type\":\"prd_item\",\"description\":\"...\",\"status\":\"pending\",\"priority\":1}'"
        exit 1
    fi
    # Create initial state
    FIRST_ITEM=$(cortex query "$TABLE" '{"type":"prd_item","status":"pending"}' | jq -r 'sort_by(.priority) | .[0].id')
    cortex put "$TABLE" "{\"id\":\"state\",\"type\":\"state\",\"current_item\":\"$FIRST_ITEM\",\"iteration\":0,\"status\":\"initialized\"}"
fi

iteration=1
while [ $iteration -le $MAX_ITERATIONS ]; do
    echo ""
    echo "========================================"
    echo "=== Ralph Iteration $iteration / $MAX_ITERATIONS ==="
    echo "========================================"

    # Get current state
    STATE=$(cortex get "$TABLE" state)
    CURRENT_ITEM=$(echo "$STATE" | jq -r '.current_item // empty')

    # Check if done
    PENDING=$(cortex query "$TABLE" '{"type":"prd_item","status":"pending"}' | jq 'length')
    if [ "$PENDING" -eq 0 ]; then
        echo "✓ All PRD items complete!"
        break
    fi

    # If no current item, pick next pending by priority
    if [ -z "$CURRENT_ITEM" ] || [ "$CURRENT_ITEM" = "null" ]; then
        CURRENT_ITEM=$(cortex query "$TABLE" '{"type":"prd_item","status":"pending"}' | \
            jq -r 'sort_by(.priority) | .[0].id')
        echo "Selected next item: $CURRENT_ITEM"
    fi

    # Get item details
    ITEM=$(cortex get "$TABLE" "$CURRENT_ITEM")
    ITEM_DESC=$(echo "$ITEM" | jq -r '.description')
    echo "Working on: $ITEM_DESC"

    # Get failures for this item
    FAILURES=$(cortex query "$TABLE" "{\"type\":\"failure\",\"prd_item\":\"$CURRENT_ITEM\"}" | jq -c '.')
    FAILURE_COUNT=$(echo "$FAILURES" | jq 'length')
    echo "Previous failures for this item: $FAILURE_COUNT"

    # Get learnings
    LEARNINGS=$(cortex query "$TABLE" '{"type":"learning"}' | jq -c '.')

    # Update state to in_progress
    cortex put "$TABLE" "{\"id\":\"state\",\"type\":\"state\",\"current_item\":\"$CURRENT_ITEM\",\"iteration\":$iteration,\"status\":\"in_progress\",\"started\":\"$(date -Iseconds)\"}"

    # Build prompt with context
    PROMPT=$(cat <<EOF
## Ralph Iteration $iteration - Cortex-Enhanced

**Project table:** $TABLE
**Current task:** $ITEM_DESC
**Task ID:** $CURRENT_ITEM

### Previous Failures for This Item
$FAILURES

### Learnings from Previous Iterations
$LEARNINGS

---

## Instructions

1. **Do NOT repeat failed approaches** - check the failures above first
2. Work on the current task until tests pass or you get stuck
3. **On discovery** - if you learn something useful for future work:
   \`\`\`bash
   cortex put $TABLE '{"id":"learning-TOPIC","type":"learning","discovery":"what you learned","iteration":$iteration}'
   \`\`\`
4. **On failure** - before stopping, record what you tried:
   \`\`\`bash
   cortex put $TABLE '{"id":"failure-$CURRENT_ITEM-$iteration","type":"failure","prd_item":"$CURRENT_ITEM","iteration":$iteration,"approach":"what you tried","error":"what happened","lesson":"what to try instead"}'
   \`\`\`
5. **On success** - mark the item complete:
   \`\`\`bash
   cortex put $TABLE '{"id":"$CURRENT_ITEM","type":"prd_item","description":"$ITEM_DESC","status":"complete","completed_iteration":$iteration}'
   \`\`\`

Begin working on: **$ITEM_DESC**
EOF
)

    # Run Claude Code
    echo ""
    echo "--- Starting Claude Code ---"
    set +e
    claude --prompt "$PROMPT"
    EXIT_CODE=$?
    set -e

    echo ""
    echo "--- Claude Code exited with code $EXIT_CODE ---"

    # Check outcome
    ITEM_STATUS=$(cortex get "$TABLE" "$CURRENT_ITEM" | jq -r '.status')

    if [ "$ITEM_STATUS" = "complete" ]; then
        echo "✓ Item $CURRENT_ITEM completed!"
        # Clear current_item for next iteration
        cortex put "$TABLE" "{\"id\":\"state\",\"type\":\"state\",\"current_item\":null,\"iteration\":$iteration,\"status\":\"item_complete\",\"completed\":\"$(date -Iseconds)\"}"
    else
        echo "Item $CURRENT_ITEM still pending (status: $ITEM_STATUS)"
        # Update state with attempt count
        cortex put "$TABLE" "{\"id\":\"state\",\"type\":\"state\",\"current_item\":\"$CURRENT_ITEM\",\"iteration\":$iteration,\"status\":\"attempted\",\"completed\":\"$(date -Iseconds)\"}"
    fi

    iteration=$((iteration + 1))

    # Brief pause between iterations
    sleep 2
done

echo ""
echo "========================================"
echo "Ralph completed after $((iteration - 1)) iterations"
echo "========================================"

# Final summary
COMPLETED=$(cortex query "$TABLE" '{"type":"prd_item","status":"complete"}' | jq 'length')
PENDING=$(cortex query "$TABLE" '{"type":"prd_item","status":"pending"}' | jq 'length')
FAILURES=$(cortex query "$TABLE" '{"type":"failure"}' | jq 'length')
LEARNINGS=$(cortex query "$TABLE" '{"type":"learning"}' | jq 'length')

echo "PRD items completed: $COMPLETED"
echo "PRD items pending: $PENDING"
echo "Total failures recorded: $FAILURES"
echo "Total learnings captured: $LEARNINGS"
