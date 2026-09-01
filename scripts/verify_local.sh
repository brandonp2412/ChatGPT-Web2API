#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

printf '%s\n' '== Backend tests =='
./.venv/bin/pytest -q

printf '%s\n' '== Backend lint =='
./.venv/bin/ruff check src tests scripts

printf '%s\n' '== Shell syntax =='
bash -n scripts/*.sh

printf '%s\n' 'Local backend verification completed successfully.'
