#!/bin/sh
# Library: exact immutable graph/dependency snapshot, no service/package actions.
# Root is explicit to allow real-filesystem fault tests without touching the host.
pe_graph_fail() { printf 'Frozen graph refused: %s\n' "$*" >&2; return 1; }
pe_graph_path() {
    case "$1" in
        /etc/sing-box/*|/etc/podkop/*|/tmp/sing-box/*|/usr/share/sing-box/*) ;;
        *) return 1;;
    esac
    case "$1" in *[!A-Za-z0-9_./+-]*|*//*|*/./*|*/../*|*/.|*/..) return 1;; esac
}
pe_graph_parent() (
    root=${1%/}; path=$2
    pe_graph_path "$path" || exit 1
    [ -d "${root:-/}" ] && [ ! -L "${root:-/}" ] && [ "$(readlink -f "${root:-/}")" = "${root:-/}" ] || exit 1
    parent=$(dirname "$path")
    while [ "$parent" != / ]; do
        [ ! -L "$root$parent" ] && { [ ! -e "$root$parent" ] || [ -d "$root$parent" ]; } || exit 1
        parent=$(dirname "$parent")
    done
)
pe_graph_collect() (
    root=${1%/}; roots=$2; output=$3
    [ -s "$roots" ] && [ -f "$roots" ] && [ ! -L "$roots" ] || exit 1
    [ ! -e "$output" ] && [ ! -L "$output" ] || exit 1
    cp "$roots" "$output.queue" || exit 1
    : > "$output" || exit 1
    count=0; bytes=0
    # Iterative closure: JSON local dependencies may themselves contain local
    # dependencies; cycles are visited once, never followed indefinitely.
    while [ -s "$output.queue" ]; do
        IFS= read -r path < "$output.queue" || exit 1
        sed '1d' "$output.queue" > "$output.queue.next" && mv "$output.queue.next" "$output.queue" || exit 1
        pe_graph_parent "$root" "$path" || { pe_graph_fail unsafe_path; exit 1; }
        grep -Fqx "$path" "$output" && continue
        file="$root$path"
        [ -f "$file" ] && [ ! -L "$file" ] || { pe_graph_fail missing_dependency; exit 1; }
        [ "$(stat -c %u "$file")" = 0 ] || { pe_graph_fail foreign_owner; exit 1; }
        size=$(wc -c < "$file") || exit 1
        bytes=$((bytes + size)); count=$((count + 1))
        [ "$count" -le 8192 ] && [ "$bytes" -le 134217728 ] || { pe_graph_fail graph_limit; exit 1; }
        printf '%s\n' "$path" >> "$output" || exit 1
        case "$path" in *.json)
            # Recursive descent includes route and DNS rules nested in groups.
            # Non-string paths and relative paths are errors, not ignored input.
            jq -e 'type=="object"' "$file" >/dev/null || exit 1
            jq -er '[..|objects|select(.type?=="local")|.path] | if all(.[];type=="string") then .[] else error("local path missing") end' "$file" > "$output.refs" 2>/dev/null || {
                # jq -e returns 4 for a valid empty stream, distinguish it from
                # parse/type failure without swallowing the latter.
                jq -e '[..|objects|select(.type?=="local")|.path]|length==0' "$file" >/dev/null || exit 1
                : > "$output.refs"
            }
            cat "$output.refs" >> "$output.queue" || exit 1;;
        *.srs) ;; # Binary rule-set bytes are frozen, not decoded/regenerated.
        *) pe_graph_fail unknown_dependency_format; exit 1;;
        esac
    done
    LC_ALL=C sort -u "$output" > "$output.sorted" && mv "$output.sorted" "$output" || exit 1
    rm -f "$output.queue" "$output.refs"
)
pe_graph_discover() (
    root=${1%/}; output=$2
    [ -f "$root/etc/sing-box/config.json" ] || exit 1
    printf '%s\n' /etc/sing-box/config.json > "$output" || exit 1
    for directory in /etc/podkop/section-runtime /etc/sing-box; do
        [ ! -e "$root$directory" ] || {
            pe_graph_parent "$root" "$directory/placeholder" && [ ! -L "$root$directory" ] || exit 1
            find "$root$directory" -type f -name '*.json' | while IFS= read -r file; do printf '%s\n' "${file#"$root"}"; done >> "$output" || exit 1
        }
    done
    LC_ALL=C sort -u "$output" > "$output.next" && mv "$output.next" "$output"
)
pe_graph_capture() (
    root=${1%/}; store=$2; roots=$3
    [ -d "$store" ] && [ ! -L "$store" ] && [ "$(readlink -f "$store")" = "$store" ] || exit 1
    [ ! -e "$store/graph.sha256" ] && [ ! -L "$store/graph.sha256" ] || exit 1
    mkdir "$store/graph.data" || exit 1
    pe_graph_collect "$root" "$roots" "$store/graph.paths" || exit 1
    : > "$store/graph.files.sha256"; : > "$store/graph.metadata"; : > "$store/graph.relative"
    while IFS= read -r path; do
        source="$root$path"; relative=${path#/}; destination="$store/graph.data/$relative"
        pe_graph_parent "$root" "$path" || exit 1
        before=$(sha256sum "$source" | awk '{print $1}') || exit 1
        metadata=$(stat -c '%u %g %a' "$source") || exit 1
        mkdir -p "$(dirname "$destination")" && cp -p "$source" "$destination" || exit 1
        [ "$before" = "$(sha256sum "$source" | awk '{print $1}')" ] && [ "$before" = "$(sha256sum "$destination" | awk '{print $1}')" ] || exit 1
        [ "$metadata" = "$(stat -c '%u %g %a' "$destination")" ] || exit 1
        printf '%s  %s\n' "$before" "$relative" >> "$store/graph.files.sha256" || exit 1
        printf '%s\t%s\n' "$metadata" "$relative" >> "$store/graph.metadata" || exit 1
        printf '%s\n' "$relative" >> "$store/graph.relative" || exit 1
    done < "$store/graph.paths"
    tar -C "$store/graph.data" -cpf "$store/graph.tar" -T "$store/graph.relative" || exit 1
    printf 'RouterDesk.FrozenGraph.v1\n' > "$store/graph.format" || exit 1
    (cd "$store" && sha256sum graph.tar graph.paths graph.relative graph.files.sha256 graph.metadata graph.format > graph.sha256.next && mv graph.sha256.next graph.sha256) || exit 1
    pe_graph_verify "$store" && pe_graph_unchanged "$root" "$store" && sync
)
pe_graph_manifest() (
    store=$1
    [ -d "$store" ] && [ ! -L "$store" ] && [ "$(readlink -f "$store")" = "$store" ] || exit 1
    [ -f "$store/graph.sha256" ] && [ ! -L "$store/graph.sha256" ] || exit 1
    [ "$(wc -l < "$store/graph.sha256")" -eq 6 ] || exit 1
    awk 'NF!=2 || length($1)!=64 || $1~/[^a-f0-9]/ || $2!~/^(graph.tar|graph.paths|graph.relative|graph.files.sha256|graph.metadata|graph.format)$/ {bad=1} {if(seen[$2]++)bad=1} END{exit bad}' "$store/graph.sha256" || exit 1
    for file in graph.tar graph.paths graph.relative graph.files.sha256 graph.metadata graph.format; do [ -f "$store/$file" ] && [ ! -L "$store/$file" ] || exit 1; done
    (cd "$store" && sha256sum -c graph.sha256 >/dev/null) || exit 1
    [ "$(cat "$store/graph.format")" = RouterDesk.FrozenGraph.v1 ] || exit 1
    while IFS= read -r path; do pe_graph_path "$path" || exit 1; done < "$store/graph.paths"
    sed 's|^/||' "$store/graph.paths" > "$store/graph.expected.next" && cmp -s "$store/graph.relative" "$store/graph.expected.next" || exit 1
    rm -f "$store/graph.expected.next"
    [ "$(wc -l < "$store/graph.paths")" -gt 0 ] && [ "$(wc -l < "$store/graph.paths")" -le 8192 ] || exit 1
    LC_ALL=C sort -u "$store/graph.relative" | cmp -s - "$store/graph.relative" || exit 1
    # Only original safe relative names can reach sha256sum -c or tar extraction.
    awk 'NF!=2 || length($1)!=64 || $1~/[^a-f0-9]/ {exit 1} {print $2}' "$store/graph.files.sha256" | cmp -s - "$store/graph.relative"
)
pe_graph_unpack() (
    store=$1; target=$2
    pe_graph_manifest "$store" || exit 1
    tar -tf "$store/graph.tar" > "$target/members" || exit 1
    cmp -s "$target/members" "$store/graph.relative" || exit 1
    # Reject links, directories, devices and extension records before extraction.
    tar -tvf "$store/graph.tar" | awk 'substr($0,1,1)!="-"{bad=1} END{exit bad}' || exit 1
    mkdir "$target/data" && tar -C "$target/data" -xpf "$store/graph.tar" || exit 1
    (cd "$target/data" && sha256sum -c "$store/graph.files.sha256" >/dev/null) || exit 1
    while IFS="$(printf '\t')" read -r metadata path; do
        pe_graph_path "/$path" && pe_graph_parent "$target/data" "/$path" || exit 1
        [ -f "$target/data/$path" ] && [ ! -L "$target/data/$path" ] && [ "$metadata" = "$(stat -c '%u %g %a' "$target/data/$path")" ] || exit 1
    done < "$store/graph.metadata"
    [ "$(wc -l < "$store/graph.metadata")" = "$(wc -l < "$store/graph.paths")" ]
)
pe_graph_verify() (
    store=$1
    pe_graph_manifest "$store" || exit 1
    scratch=$(mktemp -d "$store/graph.verify.XXXXXXXX") || exit 1
    # scratch is created here beneath the validated store, never a live path.
    trap 'rm -rf "$scratch"' EXIT INT TERM
    pe_graph_unpack "$store" "$scratch"
)
pe_graph_unchanged() (
    root=${1%/}; store=$2
    pe_graph_manifest "$store" || exit 1
    while IFS= read -r path; do pe_graph_parent "$root" "$path" && [ -f "$root$path" ] && [ ! -L "$root$path" ] || exit 1; done < "$store/graph.paths"
    (cd "${root:-/}" && sha256sum -c "$store/graph.files.sha256" >/dev/null)
)
pe_graph_restore() (
    root=${1%/}; store=$2
    pe_graph_manifest "$store" || exit 1
    scratch=$(mktemp -d "$store/graph.restore.XXXXXXXX") || exit 1
    trap 'rm -rf "$scratch"' EXIT INT TERM
    pe_graph_unpack "$store" "$scratch" || exit 1
    # Call only after independently proving ALL package writers quiescent.
    # Ephemeral dependencies first, before graph, binaries or service activation.
    for group in rules graph; do
        while IFS= read -r path; do
            case "$group:$path" in rules:/tmp/*|graph:/etc/*|graph:/usr/*) ;; *) continue;; esac
            pe_graph_parent "$root" "$path" || exit 1
            destination="$root$path"; relative=${path#/}
            [ ! -L "$destination" ] && { [ ! -e "$destination" ] || [ -f "$destination" ]; } || exit 1
            mkdir -p "$(dirname "$destination")" || exit 1
            next="$destination.routerdesk-restore.$$"
            [ ! -e "$next" ] && [ ! -L "$next" ] || exit 1
            if ! (set -C; : > "$next") || ! cp -p "$scratch/data/$relative" "$next"; then rm -f "$next"; exit 1; fi
            if [ "$(sha256sum "$next" | awk '{print $1}')" != "$(sha256sum "$scratch/data/$relative" | awk '{print $1}')" ]; then rm -f "$next"; exit 1; fi
            mv "$next" "$destination" || { rm -f "$next"; exit 1; }
        done < "$store/graph.paths"
    done
    pe_graph_unchanged "$root" "$store" && sync
)
