#!/usr/bin/env bash
# One part of Syncthing's own e2e steps against the running harness: tests/e2e-part.sh N (after chassis/tests/e2e.sh . up).
cd "$(dirname "$0")/.." && . chassis/tests/e2e.sh . none
E2E_PART=${1:?part 1-4} app_e2e_act
