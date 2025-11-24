#!/bin/bash
# Simple runner script that starts the infinite scanner with token
cd "$(dirname "$0")"

# Export the token if provided as environment variable
if [ -n "${GITLAB_TOKEN:-}" ]; then
    export GITLAB_TOKEN
fi

./infinite_scan.sh "$@"
