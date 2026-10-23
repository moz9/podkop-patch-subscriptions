#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for runtime in "$repo"/openwrt/runtime-*/usr/bin/podkop; do
  (
    log() { :; }
    subscription_services_restart_prepare() { [ "${reject_preflight:-0}" = 0 ]; }
    subscription_restart_checkpoint_create() { echo checkpoint >> "$work/events"; [ "${reject_checkpoint:-0}" = 0 ]; }
    subscription_restart_checkpoint_restore() { echo restore >> "$work/events"; cp "$work/previous" "$work/live"; }
    subscription_restart_checkpoint_discard() { echo discard >> "$work/events"; }
    stop() { echo stop >> "$work/events"; printf 'dns-bypass\n' > "$work/live"; }
    stop_main() { stop; }
    start() { echo start >> "$work/events"; [ "${late_fail:-0}" = 0 ]; }
    start_main() { start; }
    eval "$(sed -n '/^restart() {$/,/^}$/p; /^reload() {$/,/^}$/p' "$runtime")"
    for command in restart reload; do
      printf 'working-graph-and-dns\n' > "$work/previous"; cp "$work/previous" "$work/live"
      : > "$work/events"; late_fail=1
      ! "$command" || fail 'late admission failure reported success'
      cmp -s "$work/previous" "$work/live" || fail "$command left DNS/runtime changed after failed snapshot"
      [ "$(cat "$work/events")" = "$(printf 'checkpoint\nstop\nstart\nrestore\ndiscard')" ] || fail 'checkpoint/rollback order wrong'
      : > "$work/events"; late_fail=0; reject_checkpoint=1
      ! "$command" || fail 'unrecoverable restart accepted'
      [ "$(cat "$work/events")" = "$(printf 'checkpoint\ndiscard')" ] || fail 'checkpoint failure stopped service'
      : > "$work/events"; reject_checkpoint=0; reject_preflight=1
      ! "$command" || fail 'invalid admission accepted'
      [ ! -s "$work/events" ] || fail 'invalid admission mutated state'
      : > "$work/events"; reject_preflight=0
      "$command" || fail 'healthy apply rejected'
      [ "$(cat "$work/events")" = "$(printf 'checkpoint\nstop\nstart\ndiscard')" ] || fail 'successful apply rolled back or leaked checkpoint'
    done
  )
done
echo 'PASS: late start failure restores the previous runtime and DNS; preflight and backup failures never stop service'
