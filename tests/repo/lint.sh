#!/usr/bin/env bash
# Repo rules from CLAUDE.md that a machine can check, plus the .env.example templates
# labber has to be able to fill in. Needs bash 4+ (run it with tests/repo/run.sh on a Mac).
#   - .env.example: only {{ }} templates as placeholders (no changeme, no <...>), each one
#     well-formed, every generate(...) one labber knows
#   - docker-compose.yml and compose.<variant>.yml: every ${VAR} without a default is in the service's .env.example
#   - no private IP addresses (use 192.168.<vlan>.<host> names), no keys, no .env files committed
#   - no personal details: e-mail addresses, Tailscale (*.ts.net) names, city time zones, and
#     everything in your denylist (your domain, names, …: kept outside this repo, since
#     listing them here would publish them): $LINT_DENYLIST, else ../lint-denylist.txt
#     (next to this clone), else personal/lint-denylist.txt (gitignored)
#
#   lint.sh                 the working tree (every file git would push)
#   lint.sh --diff <range>  only the content rules, on the lines the commits in <range> add
#                           (the pre-push hook: a secret committed and deleted later would
#                           still be in the history)
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo" || exit 1
# shellcheck disable=SC1091
source labber/labber      # only defines functions; for TPL_RE, tpl_list, gen_known
set +e

mode=tree range=""
if [[ "${1:-}" == --diff ]]; then mode="diff"; range="${2:?--diff needs a commit range}"; fi

fail=0
err() { echo "  $1: $2"; fail=1; }

# every line to check, as "where<TAB>text": each line of each file (tree), or each line
# the commits in $range add, labelled "<commit> <file>" (diff)
all_lines() {
    if [[ "$mode" == tree ]]; then
        git ls-files -z --cached --others --exclude-standard | xargs -0 grep -nIH '' 2>/dev/null \
            | sed -E 's/^([^:]*:[0-9]+):/\1\t/'
    else
        local r; read -ra r <<< "$range"      # "a..b", or "<sha> --not --remotes"
        git log -p --no-color --format='commit %h' "${r[@]}" -- . 2>/dev/null | awk '
            /^commit /      { c = $2; next }
            /^\+\+\+ b\//    { f = substr($0, 7); next }
            /^\+\+\+ /        { next }
            /^\+/           { print c " " f "\t" substr($0, 2) }'
    fi
}
LINES=$(mktemp); trap 'rm -f "$LINES"' EXIT
all_lines > "$LINES"
# matches <ERE> (RE env, POSIX awk ERE) in the text of each line → "where<TAB>match".
# CI=1: case-insensitive. EXCL: skip lines whose "where" matches it. STRIP: removed from
# each line's text before matching (so it can't hide another match on the same line).
find_all() {
    RE="$1" CI="${2:-0}" EXCL="${3:-^\$}" STRIP="${4:-^\$}" awk -F'\t' '
        BEGIN { re = ENVIRON["RE"]; ci = ENVIRON["CI"] == "1"; ex = ENVIRON["EXCL"]; st = ENVIRON["STRIP"]; if (ci) re = tolower(re) }
        $1 ~ ex { next }
        { t = substr($0, index($0, "\t") + 1); while (gsub(st, " ", t)) ; if (ci) t = tolower(t); if (match(t, re)) print $1 "\t" substr(t, RSTART, RLENGTH) }
    ' "$LINES"
}

if [[ "$mode" == tree ]]; then
echo ":: .env.example templates"
while IFS= read -r f; do
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        val=$(env_get <(printf '%s\n' "$line") "${BASH_REMATCH[1]}")
        if [[ "$val" =~ [Cc][Hh][Aa][Nn][Gg][Ee]_?[Mm][Ee] ]]; then err "$f:$n" "old-style placeholder — use a {{ }} template"; fi
        if [[ "$val" =~ \<[a-z][^\>]*\> ]]; then err "$f:$n" "<...> placeholder — use a {{ }} template"; fi
        # every {{ must belong to a well-formed template
        rest="$val"
        while [[ "$rest" =~ $TPL_RE ]]; do rest="${rest/"${BASH_REMATCH[0]}"/}"; done
        if [[ "$rest" == *"{{"* || "$rest" == *"}}"* ]]; then err "$f:$n" "malformed template (names are lowercase; functions: default(...), generate(...), choice(...))"; fi
        while IFS=$'\t' read -r name fn arg; do
            case "$fn" in
                generate) gen_known "$arg" || err "$f:$n" "{{ $name }}: unknown generator '$arg'" ;;
                choice)   choice_known "$arg" || err "$f:$n" "{{ $name }}: choice(...) needs at least two different values" ;;
            esac
        done < <(tpl_list "$val")
    done < "$f"
done < <(git ls-files --cached --others --exclude-standard -- '*.env.example')

echo ":: compose variables"
while IFS= read -r compose; do
    dir=$(dirname "$compose")
    example_keys=""
    [[ -f "$dir/.env.example" ]] && example_keys=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$dir/.env.example" | tr -d ' =')
    # ${VAR} and ${VAR:?msg} need a value; ${VAR:-x} / ${VAR-x} have a default; $$ is a literal $
    while IFS= read -r var; do
        grep -qx "$var" <<< "$example_keys" || err "$compose" "\${$var} has no default and isn't in .env.example"
    done < <(sed 's/\$\$//g' "$compose" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(:?\?[^}]*)?\}' \
                | sed -E 's/^\$\{([A-Za-z0-9_]+).*/\1/' | sort -u)
done < <(git ls-files --cached --others --exclude-standard -- '*docker-compose.yml' 'services/*/compose.*.yml')

fi   # tree-only checks

echo ":: private IP addresses"
# documentation ranges (192.0.2.x, 198.51.100.x, 203.0.113.x) and public ones are fine;
# the unit tests use 10.0.0.x as made-up data. Wide generic ranges (a.b.0.0/16 or wider,
# e.g. Docker's 172.16.0.0/12) say nothing about a network and are fine too; a /24 or a
# host is not.
while IFS=$'\t' read -r where ip; do
    err "$where" "private IP ${ip//[^0-9.]/} — write 192.168.<vlan>.<host> instead"
done < <(find_all '(^|[^0-9.])(192[.]168|10[.][0-9]{1,3}|172[.](1[6-9]|2[0-9]|3[01]))[.][0-9]{1,3}[.][0-9]{1,3}([^0-9.]|$)' 0 '^(tests/labber/unit[.]bats|[0-9a-f]+ tests/labber/unit[.]bats)' \
    '(^|[^0-9.])[0-9]{1,3}[.][0-9]{1,3}[.]0[.]0/([0-9]|1[0-6])([^0-9]|$)')

echo ":: keys"
# private keys never; SSH public keys don't belong here either (tests make their own)
while IFS=$'\t' read -r where _; do
    err "$where" "key material — generate keys at run time, keep real ones out of the repo"
done < <(find_all '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
         find_all '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh[.]com) AAAA[0-9A-Za-z+/]{20,}')

echo ":: personal details"
# e-mail addresses (placeholders like x@y.com / example.org and noreply addresses are fine)
while IFS=$'\t' read -r where m; do
    m="${m%[!A-Za-z0-9]}"      # the match ends with the character after the address
    [[ "${m,,}" =~ (noreply|@example[.](com|org|net)$|^x@y[.]com$) ]] && continue
    err "$where" "e-mail address $m — keep personal details out of the repo"
done < <(find_all '[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.](com|net|org|dev|io|me|uk|de|in|co|app|info|eu|xyz|ai)([^a-z0-9.-]|$)' 1)
while IFS=$'\t' read -r where m; do err "$where" "Tailscale name $m — keep machine names out of the repo"; done \
    < <(find_all '[a-z0-9-]+[.][a-z0-9-]+[.]ts[.]net' 1)
while IFS=$'\t' read -r where m; do err "$where" "time zone $m — a location; use a {{ tz | default(Etc/UTC) }} template"; done \
    < <(find_all '(Europe|America|Asia|Africa|Australia|Pacific|Atlantic|Indian|Antarctica)/[A-Z][A-Za-z_]+')
# your own list — one case-insensitive ERE per line, # comments
denylist="${LINT_DENYLIST:-}"
if [[ -z "$denylist" ]]; then
    for f in ../lint-denylist.txt personal/lint-denylist.txt; do [[ -f "$f" ]] && { denylist="$f"; break; }; done
fi
if [[ -n "$denylist" && -f "$denylist" ]]; then
    while IFS= read -r pat || [[ -n "$pat" ]]; do
        pat="${pat%%#*}"; pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
        [[ -n "$pat" ]] || continue
        while IFS=$'\t' read -r where m; do err "$where" "matches your denylist ($m)"; done < <(find_all "$pat" 1)
    done < "$denylist"
else
    echo "  (no denylist: ../lint-denylist.txt or personal/lint-denylist.txt — add your domain, names, e-mail to check for them too)"
fi

if [[ "$mode" == tree ]]; then
    echo ":: committed .env files"
    while IFS= read -r f; do err "$f" ".env files must never be committed (use .env.example)"; done \
        < <(git ls-files --cached --others --exclude-standard | grep -E '(^|/)\.env$')
fi

if (( fail )); then echo "lint: problems found"; exit 1; fi
echo "lint: ok"
