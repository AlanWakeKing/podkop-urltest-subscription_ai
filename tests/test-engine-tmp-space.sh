#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
work_dir=$(mktemp -d)
function_file="$work_dir/functions.sh"
trap 'rm -rf "$work_dir"' EXIT

if ! awk '
    /^engine_tmp_space_ready\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 1) exit }
    END { if (blocks != 1) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: tmp space preflight function missing' >&2
    exit 1
fi
. "$function_file"

df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    case "${TEST_DF_MODE:-normal}" in
        normal) printf 'tmpfs 100000 1 %s 1%% /tmp\n' "$TEST_TMP_FREE_KB" ;;
        reordered)
            printf 'overlay 100000 1 1 1%% /overlay\n'
            printf 'tmpfs 100000 1 %s 1%% /tmp\n' "$TEST_TMP_FREE_KB"
            ;;
        duplicate)
            printf 'tmpfs 100000 1 %s 1%% /tmp\n' "$TEST_TMP_FREE_KB"
            printf 'tmpfs 100000 1 %s 1%% /tmp\n' "$TEST_TMP_FREE_KB"
            ;;
        missing) printf 'overlay 100000 1 %s 1%% /overlay\n' "$TEST_TMP_FREE_KB" ;;
        *) return 1 ;;
    esac
}

TEST_TMP_FREE_KB=35001
export TEST_TMP_FREE_KB
engine_tmp_space_ready 1024 35000 || { echo 'FAIL: exact reserve plus 1 KB package was rejected' >&2; exit 1; }
echo 'PASS: package download space includes the reserve'

TEST_DF_MODE=reordered
TEST_TMP_FREE_KB=35001
export TEST_DF_MODE TEST_TMP_FREE_KB
engine_tmp_space_ready 1024 35000 || { echo 'FAIL: /tmp space parser depended on df row order' >&2; exit 1; }
echo 'PASS: /tmp capacity parser finds the exact mount row after unrelated rows'

TEST_DF_MODE=duplicate
TEST_TMP_FREE_KB=99999
export TEST_DF_MODE TEST_TMP_FREE_KB
if engine_tmp_space_ready 1024 35000; then
    echo 'FAIL: ambiguous duplicate /tmp df rows were accepted' >&2
    exit 1
fi

echo 'PASS: duplicate /tmp capacity rows fail closed'

TEST_DF_MODE=missing
TEST_TMP_FREE_KB=99999
export TEST_DF_MODE TEST_TMP_FREE_KB
if engine_tmp_space_ready 1024 35000; then
    echo 'FAIL: df output without a /tmp row was accepted' >&2
    exit 1
fi
unset TEST_DF_MODE
echo 'PASS: missing /tmp capacity row fails closed'

if grep -E 'df -Pk /tmp.*NR[[:space:]]*==[[:space:]]*2' "$UPDATE_SCRIPT" >/dev/null; then
    echo 'FAIL: a /tmp capacity call site bypasses the validated parser' >&2
    exit 1
fi
TEST_DF_MODE=reordered
TEST_TMP_FREE_KB=35000
export TEST_DF_MODE TEST_TMP_FREE_KB
engine_tmp_space_ready 1 34999 || { echo 'FAIL: post-download 35 MB headroom check rejected reordered df output' >&2; exit 1; }
echo 'PASS: post-download reserve check uses the validated /tmp parser'

TEST_DF_MODE=duplicate
TEST_TMP_FREE_KB=99999
export TEST_DF_MODE TEST_TMP_FREE_KB
if engine_tmp_space_ready 1 34999; then
    echo 'FAIL: post-download reserve check accepted duplicate /tmp rows' >&2
    exit 1
fi
TEST_DF_MODE=missing
export TEST_DF_MODE
if engine_tmp_space_ready 1 34999; then
    echo 'FAIL: post-download reserve check accepted missing /tmp row' >&2
    exit 1
fi
unset TEST_DF_MODE
echo 'PASS: post-download reserve check fails closed on ambiguous /tmp data'

TEST_TMP_FREE_KB=35000
export TEST_TMP_FREE_KB
if engine_tmp_space_ready 1024 35000; then
    echo 'FAIL: download that consumes reserved space was accepted' >&2
    exit 1
fi
echo 'PASS: insufficient download headroom rejected'

TEST_TMP_FREE_KB=45240
export TEST_TMP_FREE_KB
engine_tmp_space_ready 10485760 35000 || { echo 'FAIL: exact 10 MiB plus reserve was rejected' >&2; exit 1; }
TEST_TMP_FREE_KB=45239
export TEST_TMP_FREE_KB
if engine_tmp_space_ready 10485760 35000; then
    echo 'FAIL: one KB below required space was accepted' >&2
    exit 1
fi
echo 'PASS: byte-size rounded up to required KiB'

if engine_tmp_space_ready bad 35000; then
    echo 'FAIL: malformed asset size was accepted' >&2
    exit 1
fi
echo 'PASS: malformed asset size rejected'

TEST_TMP_FREE_KB=99999999
export TEST_TMP_FREE_KB
for oversized_bytes in 2147483648 999999999999999999999999999; do
    if engine_tmp_space_ready "$oversized_bytes" 35000; then
        echo "FAIL: overflow-sized package asset accepted ($oversized_bytes)" >&2
        exit 1
    fi
done
if engine_tmp_space_ready 1024 2147483647; then
    echo 'FAIL: overflow-sized reserve accepted' >&2
    exit 1
fi
echo 'PASS: oversized package and reserve metadata rejected before arithmetic overflow'
