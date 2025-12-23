#!/bin/bash
# generate-test-data.sh
# Generates protocol-test-data.json from shared/protocol.def
# This JSON file is used by both Swift and C# tests to verify cross-platform parity.
#
# Usage: ./scripts/generate-test-data.sh [output-path]
# Default output: shared/protocol-test-data.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PROTOCOL_DEF="$REPO_ROOT/shared/protocol.def"
OUTPUT_PATH="${1:-$REPO_ROOT/shared/protocol-test-data.json}"

if [[ ! -f "$PROTOCOL_DEF" ]]; then
    echo "Error: protocol.def not found at $PROTOCOL_DEF" >&2
    exit 1
fi

# Parse protocol.def and output JSON
awk '
BEGIN {
    section = ""
    first_in_section = 1
    print "{"
}

# Skip comments and empty lines
/^[[:space:]]*#/ { next }
/^[[:space:]]*$/ { next }

# Section headers
/^\[.*\]$/ {
    if (section != "") {
        print "  },"
    }
    gsub(/[\[\]]/, "")
    section = $0
    
    # Convert SECTION_NAME to camelCase
    n = split(section, parts, "_")
    camel = tolower(parts[1])
    for (i = 2; i <= n; i++) {
        camel = camel toupper(substr(parts[i], 1, 1)) tolower(substr(parts[i], 2))
    }
    
    printf "  \"%s\": {\n", camel
    first_in_section = 1
    next
}

# Key = Value pairs
/=/ {
    split($0, kv, "=")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[2])
    
    key = kv[1]
    value = kv[2]
    
    # Convert KEY_NAME to camelCase
    n = split(key, parts, "_")
    camel = tolower(parts[1])
    for (i = 2; i <= n; i++) {
        camel = camel toupper(substr(parts[i], 1, 1)) tolower(substr(parts[i], 2))
    }
    
    # Determine if value is numeric or string
    if (value ~ /^0x[0-9a-fA-F]+$/) {
        # Hex number - convert to decimal
        hex = substr(value, 3)
        dec = 0
        for (i = 1; i <= length(hex); i++) {
            c = substr(hex, i, 1)
            if (c ~ /[0-9]/) d = c + 0
            else if (c ~ /[aA]/) d = 10
            else if (c ~ /[bB]/) d = 11
            else if (c ~ /[cC]/) d = 12
            else if (c ~ /[dD]/) d = 13
            else if (c ~ /[eE]/) d = 14
            else if (c ~ /[fF]/) d = 15
            dec = dec * 16 + d
        }
        value = dec
        is_string = 0
    } else if (value ~ /^[0-9]+$/) {
        # Decimal number
        is_string = 0
    } else {
        # String value
        is_string = 1
    }
    
    if (!first_in_section) {
        print ","
    }
    first_in_section = 0
    
    if (is_string) {
        printf "    \"%s\": \"%s\"", camel, value
    } else {
        printf "    \"%s\": %s", camel, value
    }
}

END {
    if (section != "") {
        print ""
        print "  }"
    }
    print "}"
}
' "$PROTOCOL_DEF" > "$OUTPUT_PATH"

echo "✅ Generated $OUTPUT_PATH"
