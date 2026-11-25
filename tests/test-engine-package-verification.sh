#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
function_file=$(mktemp)
work_dir=$(mktemp -d)
trap 'rm -f "$function_file"; rm -rf "$work_dir"' EXIT
if ! awk '
    /^(engine_binary_version_for_package|engine_ipk_control_valid|engine_ipk_control_field|engine_ipk_install_contracts_match|verify_engine_ipk|verify_stock_sing_box_ipk)\(\) \{$/ { capture = 1; blocks++ }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture = 0; if (blocks == 6) exit }
    END { if (blocks != 6) exit 1 }
' "$UPDATE_SCRIPT" > "$function_file"; then
    echo 'FAIL: package verification functions are missing from update.sh' >&2
    exit 1
fi
. "$function_file"

build_ipk() {
    dir=$1
    package_name=$2
    package_version=$3
    binary_version=$4
    output=$5
    depends=$6
    pre_depends=${7:-}
    conflicts=${8-'sing-box, sing-box-tiny'}
    breaks=${9-}
    replaces=${10-}
    provides=${11-sing-box}
    architecture=${12-aarch64_cortex-a53}
    omit_field=${13-}
    duplicate_field=${14-}
    malformed_line=${15-}
    mkdir -p "$dir/control" "$dir/data/usr/bin"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nDepends: %s\n' \
        "$package_name" "$package_version" "$architecture" "$depends" > "$dir/control/control"
    printf 'Pre-Depends: %s\nConflicts: %s\nBreaks: %s\nReplaces: %s\nProvides: %s\n' \
        "$pre_depends" "$conflicts" "$breaks" "$replaces" "$provides" >> "$dir/control/control"
    if [ -n "$omit_field" ]; then
        awk -v field="$omit_field" 'index($0, field ":") != 1' "$dir/control/control" > "$dir/control/control.tmp"
        mv "$dir/control/control.tmp" "$dir/control/control"
    fi
    [ -z "$duplicate_field" ] || printf '%s: duplicate-value\n' "$duplicate_field" >> "$dir/control/control"
    [ -z "$malformed_line" ] || printf '%s\n' "$malformed_line" >> "$dir/control/control"
    printf '#!/bin/sh\n[ "$1" = version ] && printf "sing-box version %s\\n" "%s"\n' \
        "$binary_version" "$binary_version" > "$dir/data/usr/bin/sing-box"
    chmod 755 "$dir/data/usr/bin/sing-box"
    (cd "$dir/control" && tar czf "$dir/control.tar.gz" ./control)
    (cd "$dir/data" && tar czf "$dir/data.tar.gz" ./usr)
    (cd "$dir" && tar czf "$output" ./control.tar.gz ./data.tar.gz)
}

build_ipk "$work_dir/good" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/good.ipk" 'libc, ca-bundle'
if verify_engine_ipk "$work_dir/good.ipk" 1.14.4-r27 "$work_dir/extracted-good" aarch64_cortex-a53; then
    echo 'PASS: exact package metadata and binary version verified'
else
    echo 'FAIL: valid engine package was rejected' >&2
    exit 1
fi

if verify_engine_ipk "$work_dir/good.ipk" 1.14.4-r28 "$work_dir/extracted-wrong-version" aarch64_cortex-a53; then
    echo 'FAIL: package with wrong version was accepted' >&2
    exit 1
else
    echo 'PASS: wrong package version rejected'
fi

if verify_engine_ipk "$work_dir/good.ipk" 1.14.4-r27 "$work_dir/extracted-wrong-arch" x86_64; then
    echo 'FAIL: package with wrong architecture was accepted' >&2
    exit 1
else
    echo 'PASS: wrong package architecture rejected'
fi

printf 'not-an-ipk\n' > "$work_dir/malformed.ipk"
if verify_engine_ipk "$work_dir/malformed.ipk" 1.14.4-r27 "$work_dir/extracted-malformed" aarch64_cortex-a53; then
    echo 'FAIL: malformed package was accepted' >&2
    exit 1
else
    echo 'PASS: malformed package rejected'
fi

build_ipk "$work_dir/wrong-name" podkop-engine-full 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/wrong-name.ipk" 'libc, ca-bundle'
if verify_engine_ipk "$work_dir/wrong-name.ipk" 1.14.4-r27 "$work_dir/extracted-wrong-name" aarch64_cortex-a53; then
    echo 'FAIL: package with wrong name was accepted' >&2
    exit 1
else
    echo 'PASS: wrong package name rejected'
fi

build_ipk "$work_dir/wrong-binary" podkop-engine 1.14.4-r27 1.14.4-pdk-r28 "$work_dir/wrong-binary.ipk" 'libc, ca-bundle'
if verify_engine_ipk "$work_dir/wrong-binary.ipk" 1.14.4-r27 "$work_dir/extracted-wrong-binary" aarch64_cortex-a53; then
    echo 'FAIL: package with mismatched binary version was accepted' >&2
    exit 1
else
    echo 'PASS: package/binary version mismatch rejected'
fi

for missing_field in Depends Conflicts Provides Architecture; do
    build_ipk "$work_dir/missing-$missing_field" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
        "$work_dir/missing-$missing_field.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' sing-box aarch64_cortex-a53 "$missing_field"
    if verify_engine_ipk "$work_dir/missing-$missing_field.ipk" 1.14.4-r27 \
        "$work_dir/extracted-missing-$missing_field" aarch64_cortex-a53; then
        printf 'FAIL: package with missing %s metadata was accepted\n' "$missing_field" >&2
        exit 1
    fi
    printf 'PASS: missing %s metadata rejected\n' "$missing_field"
done

build_ipk "$work_dir/empty-depends" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
    "$work_dir/empty-depends.ipk" ''
if verify_engine_ipk "$work_dir/empty-depends.ipk" 1.14.4-r27 "$work_dir/extracted-empty-depends" aarch64_cortex-a53; then
    echo 'FAIL: package with empty Depends metadata was accepted' >&2
    exit 1
fi
echo 'PASS: empty Depends metadata rejected'

for empty_field in Conflicts Provides Architecture; do
    case "$empty_field" in
        Conflicts)
            build_ipk "$work_dir/empty-$empty_field" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
                "$work_dir/empty-$empty_field.ipk" 'libc, ca-bundle' '' '' '' '' sing-box ;;
        Provides)
            build_ipk "$work_dir/empty-$empty_field" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
                "$work_dir/empty-$empty_field.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' '' ;;
        Architecture)
            build_ipk "$work_dir/empty-$empty_field" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
                "$work_dir/empty-$empty_field.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' sing-box '' ;;
    esac
    if verify_engine_ipk "$work_dir/empty-$empty_field.ipk" 1.14.4-r27 \
        "$work_dir/extracted-empty-$empty_field" aarch64_cortex-a53; then
        printf 'FAIL: package with empty %s metadata was accepted\n' "$empty_field" >&2
        exit 1
    fi
    printf 'PASS: empty %s metadata rejected\n' "$empty_field"
done

build_ipk "$work_dir/duplicate-control" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
    "$work_dir/duplicate-control.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' sing-box aarch64_cortex-a53 '' Depends
if verify_engine_ipk "$work_dir/duplicate-control.ipk" 1.14.4-r27 "$work_dir/extracted-duplicate" aarch64_cortex-a53; then
    echo 'FAIL: duplicate control field was accepted' >&2
    exit 1
fi
echo 'PASS: duplicate control field rejected'

build_ipk "$work_dir/malformed-control" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 \
    "$work_dir/malformed-control.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' sing-box aarch64_cortex-a53 '' '' 'invalid-control-line'
if verify_engine_ipk "$work_dir/malformed-control.ipk" 1.14.4-r27 "$work_dir/extracted-malformed-control" aarch64_cortex-a53; then
    echo 'FAIL: malformed control record was accepted' >&2
    exit 1
fi
echo 'PASS: malformed control record rejected'

build_ipk "$work_dir/candidate" podkop-engine 1.14.4-r28 1.14.4-pdk-r28 "$work_dir/candidate.ipk" 'libc, ca-bundle'
if engine_ipk_install_contracts_match "$work_dir/candidate.ipk" "$work_dir/duplicate-control.ipk"; then
    echo 'FAIL: install-contract comparison accepted duplicate control fields' >&2
    exit 1
fi
echo 'PASS: install-contract comparison rejects duplicate control fields'
build_ipk "$work_dir/rollback-same-deps" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-same-deps.ipk" 'libc, ca-bundle'
if engine_ipk_install_contracts_match "$work_dir/candidate.ipk" "$work_dir/rollback-same-deps.ipk"; then
    echo 'PASS: identical candidate and rollback dependencies accepted'
else
    echo 'FAIL: identical dependencies were rejected' >&2
    exit 1
fi

build_ipk "$work_dir/rollback-different-deps" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-deps.ipk" 'libc'
if engine_ipk_install_contracts_match "$work_dir/candidate.ipk" "$work_dir/rollback-different-deps.ipk"; then
    echo 'FAIL: rollback package with different dependencies was accepted' >&2
    exit 1
else
    echo 'PASS: rollback dependency mismatch rejected'
fi

build_ipk "$work_dir/rollback-different-conflicts" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-conflicts.ipk" 'libc, ca-bundle' '' 'sing-box'
if engine_ipk_install_contracts_match "$work_dir/candidate.ipk" "$work_dir/rollback-different-conflicts.ipk"; then
    echo 'FAIL: rollback package with different conflicts was accepted' >&2
    exit 1
else
    echo 'PASS: rollback install-contract mismatch rejected'
fi

build_ipk "$work_dir/rollback-different-pre-depends" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-pre-depends.ipk" 'libc, ca-bundle' libc
build_ipk "$work_dir/rollback-different-breaks" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-breaks.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' 'old-engine'
build_ipk "$work_dir/rollback-different-replaces" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-replaces.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' 'old-engine'
build_ipk "$work_dir/rollback-different-provides" podkop-engine 1.14.4-r27 1.14.4-pdk-r27 "$work_dir/rollback-different-provides.ipk" 'libc, ca-bundle' '' 'sing-box, sing-box-tiny' '' '' 'other-engine'
for mismatch in pre-depends breaks replaces provides; do
    if engine_ipk_install_contracts_match "$work_dir/candidate.ipk" "$work_dir/rollback-different-$mismatch.ipk"; then
        printf 'FAIL: rollback package with different %s was accepted\n' "$mismatch" >&2
        exit 1
    fi
    printf 'PASS: rollback %s mismatch rejected\n' "$mismatch"
done

build_ipk "$work_dir/stock" sing-box 1.12.22-r1 1.12.22 "$work_dir/stock.ipk" 'libc, ca-bundle'
stock_binary_version=$(verify_stock_sing_box_ipk "$work_dir/stock.ipk" 1.12.22-r1 \
    "$work_dir/stock-binary" aarch64_cortex-a53) || { echo 'FAIL: valid stock sing-box IPK rejected' >&2; exit 1; }
[ "$stock_binary_version" = 'sing-box version 1.12.22' ] || { echo 'FAIL: stock binary version was not captured exactly' >&2; exit 1; }
[ -x "$work_dir/stock-binary" ] || { echo 'FAIL: stock binary was not extracted' >&2; exit 1; }
echo 'PASS: exact stock IPK and binary version verified'

if verify_stock_sing_box_ipk "$work_dir/stock.ipk" 1.12.23-r1 "$work_dir/stock-wrong-version" aarch64_cortex-a53 >/dev/null; then
    echo 'FAIL: stock IPK with wrong package version accepted' >&2
    exit 1
fi
echo 'PASS: wrong stock package version rejected'
if verify_stock_sing_box_ipk "$work_dir/stock.ipk" 1.12.22-r1 "$work_dir/stock-wrong-arch" x86_64 >/dev/null; then
    echo 'FAIL: stock IPK with wrong architecture accepted' >&2
    exit 1
fi
echo 'PASS: wrong stock package architecture rejected'
