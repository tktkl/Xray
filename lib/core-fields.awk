# Inventory JSON declarations without compiling or executing upstream source.
FNR == 1 { scope = "anonymous"; comment = 0 }
{
    line = $0
    if (comment) {
        if (!match(line, /\*\//)) next
        line = substr(line, RSTART + RLENGTH); comment = 0
    }
    while (match(line, /\/\*/)) {
        before = substr(line, 1, RSTART - 1); rest = substr(line, RSTART + 2)
        if (!match(rest, /\*\//)) { line = before; comment = 1; break }
        line = before substr(rest, RSTART + RLENGTH)
    }
    sub(/\/\/.*/, "", line)
    if (line ~ /^[[:space:]]*type[[:space:]]+[[:alnum:]_]+.*struct[[:space:]]*\{/) {
        scope = line; sub(/^[[:space:]]*type[[:space:]]+/, "", scope)
        sub(/[^[:alnum:]_].*$/, "", scope)
    }
    while (match(line, /json:"[^"\\]*"/)) {
        field = substr(line, RSTART + 6, RLENGTH - 7)
        sub(/,.*/, "", field)
        if (field != "" && field != "-") {
            if (field !~ /^[[:alnum:]_.-]+$/) exit 1
            file = substr(FILENAME, length(root) + 1)
            print file ":" scope "." field
        }
        line = substr(line, RSTART + RLENGTH)
    }
}
