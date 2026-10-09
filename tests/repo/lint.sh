#!/usr/bin/env bash
# Repo rules from CLAUDE.md that a machine can check, plus the .env.example templates
# labber has to be able to fill in. Needs bash 4+ (run it with tests/repo/run.sh on a Mac).
#   - .env.example: only {{ }} templates as placeholders (no changeme, no <...>), each one
#     well-formed, every generate(...) one labber knows
#   - docker-compose.yml: every ${VAR} without a default is in the service's .env.example
#   - no private IP addresses (use 192.168.<vlan>.<host> names), no keys, no .env files committed
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
# shellcheck disable=SC1091
source labber/labber      # only defines functions; for TPL_RE, tpl_list, gen_known
set +e

fail=0
err() { echo "  $1: $2"; fail=1; }

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
        if [[ "$rest" == *"{{"* || "$rest" == *"}}"* ]]; then err "$f:$n" "malformed template (names are lowercase; functions: default(...), generate(...))"; fi
        while IFS=$'\t' read -r name fn arg; do
            [[ "$fn" == generate ]] || continue
            gen_known "$arg" || err "$f:$n" "{{ $name }}: unknown generator '$arg'"
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
done < <(git ls-files --cached --others --exclude-standard -- '*docker-compose.yml')

echo ":: private IP addresses"
# documentation ranges (192.0.2.x, 198.51.100.x, 203.0.113.x) and public ones are fine;
# the unit tests use 10.0.0.x as made-up data
while IFS=: read -r f n ip; do
    err "$f:$n" "private IP $ip — write 192.168.<vlan>.<host> instead"
done < <(git ls-files -z --cached --others --exclude-standard | xargs -0 grep -nIoE '\b(192\.168|10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' 2>/dev/null \
            | grep -v '^tests/labber/unit\.bats:')

echo ":: keys"
# private keys never; SSH public keys don't belong here either (tests make their own)
while IFS=: read -r f n _; do
    err "$f:$n" "key material — generate keys at run time, keep real ones out of the repo"
done < <(git ls-files -z --cached --others --exclude-standard | xargs -0 grep -nIE \
            -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' \
            -e '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com) AAAA[0-9A-Za-z+/]{20,}' 2>/dev/null)

echo ":: committed .env files"
while IFS= read -r f; do err "$f" ".env files must never be committed (use .env.example)"; done \
    < <(git ls-files --cached --others --exclude-standard | grep -E '(^|/)\.env$')

if (( fail )); then echo "lint: problems found"; exit 1; fi
echo "lint: ok"
