#!/bin/bash
# Builds a tree-sitter grammar into a dynamic library an Oh My Code extension can ship
# (`contributes.treeSitterGrammars`): src/parser.c, plus src/scanner.c (or scanner.cc) when
# the grammar has one, compiled for Apple silicon and Intel and signed ad hoc.
#
#   build-tree-sitter-grammar.sh <grammar-folder> [output.dylib]
#
# <grammar-folder> is a grammar repository (tree-sitter-foo) or its src folder, with the
# generated parser.c (run `tree-sitter generate` first if the repository doesn't commit it).
# The output defaults to ./libtree-sitter-<name>.dylib, <name> read from parser.c's
# `tree_sitter_<name>` function: that's the "symbol" to put in extension.json.
#
# Environment: ARCHS (default "arm64 x86_64"), MACOSX_DEPLOYMENT_TARGET (default 13.0),
# CC (default clang), CFLAGS (added to the compiler's flags), SIGN_IDENTITY (default "-":
# ad hoc; a "Developer ID Application: …" identity signs it for distribution).
set -euo pipefail

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

grammar="${1%/}"
if [[ -f "$grammar/src/parser.c" ]]; then
    src="$grammar/src"
elif [[ -f "$grammar/parser.c" ]]; then
    src="$grammar"
else
    echo "error: no parser.c in $grammar or $grammar/src (run \`tree-sitter generate\` in the grammar first)" >&2
    exit 1
fi

name=$(grep -oE 'tree_sitter_[A-Za-z0-9_]+\(void\)' "$src/parser.c" | head -1 | sed -E 's/tree_sitter_(.*)\(void\)/\1/')
if [[ -z "$name" ]]; then
    echo "error: parser.c has no tree_sitter_<name>(void) function" >&2
    exit 1
fi
output="${2:-./libtree-sitter-$name.dylib}"
mkdir -p "$(dirname "$output")"

cc="${CC:-clang}"
archs=()
for arch in ${ARCHS:-arm64 x86_64}; do archs+=(-arch "$arch"); done
flags=(-O2 -fPIC -I "$src" -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-13.0}" "${archs[@]}")
# shellcheck disable=SC2206
extra=(${CFLAGS:-})

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
objects=()
"$cc" -c -std=c11 "${flags[@]}" ${extra[@]+"${extra[@]}"} -o "$work/parser.o" "$src/parser.c"
objects+=("$work/parser.o")
linker="$cc"
if [[ -f "$src/scanner.c" ]]; then
    "$cc" -c -std=c11 "${flags[@]}" ${extra[@]+"${extra[@]}"} -o "$work/scanner.o" "$src/scanner.c"
    objects+=("$work/scanner.o")
elif [[ -f "$src/scanner.cc" ]]; then
    cxx="${CXX:-clang++}"
    "$cxx" -c -std=c++17 "${flags[@]}" ${extra[@]+"${extra[@]}"} -o "$work/scanner.o" "$src/scanner.cc"
    objects+=("$work/scanner.o")
    linker="$cxx"
fi

"$linker" -dynamiclib "${archs[@]}" -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
    -install_name "@rpath/$(basename "$output")" -o "$output" "${objects[@]}"

codesign --force --sign "${SIGN_IDENTITY:--}" "$output"

symbol=$(nm -gU "$output" 2>/dev/null | grep -oE '_tree_sitter_[A-Za-z0-9_]+' | head -1 | sed 's/^_//')
echo "Built $output"
echo "  architectures: $(lipo -archs "$output")"
echo "  symbol: ${symbol:-tree_sitter_$name}"
