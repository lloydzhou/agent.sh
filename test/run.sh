#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n agent.sh
bash test/smoke.sh
for test in test/*_regression.py; do
    python3 "$test"
done
