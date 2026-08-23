#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
"$ROOT/Scripts/tests/validate_release_branch_test.sh"
"$ROOT/Scripts/tests/release_common_test.sh"
"$ROOT/Scripts/tests/build_developer_id_test.sh"
"$ROOT/Scripts/tests/sign_dmg_test.sh"
"$ROOT/Scripts/tests/prepare_release_test.sh"
"$ROOT/Scripts/tests/publish_release_test.sh"
echo "All release tool tests passed"
