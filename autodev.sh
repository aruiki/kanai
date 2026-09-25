#!/usr/bin/env bash

set -u
set -o pipefail

cd "$(dirname "$0")"

mkdir -p .autodev

MODEL="opencode/space-bunny-free"
ITERATION=0

echo "============================================"
echo " Autonomous IME development started"
echo " Model: $MODEL"
echo " Project: $(pwd)"
echo "============================================"

while true; do

    if [ -f .goal-complete ]; then
        echo
        echo "============================================"
        echo " GOAL COMPLETE"
        echo " Verified by independent verifier"
        echo "============================================"
        exit 0
    fi

    ITERATION=$((ITERATION + 1))

    echo
    echo "============================================"
    echo " Developer iteration $ITERATION"
    echo " $(date)"
    echo "============================================"

    if [ "$ITERATION" -eq 1 ] && [ ! -f VERIFICATION.md ]; then
        PROMPT_FILE="INITIAL_PROMPT.md"
    else
        PROMPT_FILE="LOOP_PROMPT.md"
    fi

    timeout --signal=TERM --kill-after=30s 90m \
        opencode run \
        --agent build \
        --model "$MODEL" \
        "$(cat "$PROMPT_FILE")" \
        2>&1 | tee -a .autodev/developer.log

    DEV_EXIT=${PIPESTATUS[0]}

    echo
    echo "Developer exit code: $DEV_EXIT"

    if [ -f .goal-complete ]; then
        echo "WARNING: developer unexpectedly produced .goal-complete"
        rm -f .goal-complete
    fi

    echo
    echo "============================================"
    echo " Independent verification $ITERATION"
    echo "============================================"

    timeout --signal=TERM --kill-after=30s 60m \
        opencode run \
        --agent verifier \
        --model "$MODEL" \
        "$(cat VERIFY_PROMPT.md)" \
        2>&1 | tee -a .autodev/verifier.log

    VERIFY_EXIT=${PIPESTATUS[0]}

    echo
    echo "Verifier exit code: $VERIFY_EXIT"

    if [ -f .goal-complete ]; then
        echo
        echo "============================================"
        echo " GOAL COMPLETE"
        echo " All automated acceptance criteria passed"
        echo "============================================"
        exit 0
    fi

    echo
    echo "Goal is still incomplete."

    if [ "$DEV_EXIT" -ne 0 ] || [ "$VERIFY_EXIT" -ne 0 ]; then
        echo "A process failed or timed out. Waiting 30 seconds..."
        sleep 30
    else
        echo "Starting next development iteration in 5 seconds..."
        sleep 5
    fi

done
