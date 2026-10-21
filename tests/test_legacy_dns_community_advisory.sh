#!/bin/sh
set -eu
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
eval "$(sed '/^case "${1:-}" in/,$d' "$repo/openwrt/podkop-dns-optimizer")"
fail() { echo "FAIL: $*" >&2; exit 1; }
# Preserve actual selected-community extraction, compatibility domains, counts,
# bootstrap selection, NXDOMAIN gate, community rows and score arithmetic.
uci() {
    case "$*" in
      *'show podkop') echo "podkop.main.connection_type='proxy'";;
      *podkop.main.connection_type) echo proxy;;
      *podkop.main.community_lists) echo 'anime hdrezka youtube google_ai';;
      *) return 1;;
    esac
}
printf '%s\n' '[{"id":"google_1","server":"8.8.8.8","provider":"Google","profile":"unfiltered","reliable":true,"successRate":100,"medianMs":5,"p90Ms":5,"jitterMs":0}]' > "$work/bootstrap.json"
run_dns_query() {
    printf '%s\n' "$5" >> "$work/queries"
    [ "$5" != "${mandatory_fail:-none}" ] || return 1
    if [ "$6" = NXDOMAIN ]; then [ "${bad_nx:-0}" = 0 ] || return 1; fi
    case "$5" in
      hdrezka.ag|hdrezka.me|shikimori.one|mangadex.org|youtube.com|googlevideo.com|gemini.google.com|generativelanguage.googleapis.com)
        if [ "${community_mode:-bad}" = bad ]; then return 1; fi
        if [ "${community_mode:-bad}" = unstable ]; then
            count="$(grep -Fxc "$5" "$work/queries")"
            [ "$count" -lt 2 ] || return 1
        fi;;
    esac
    echo 5
}
benchmark_main_candidate udp cloudflare Cloudflare 1.1.1.1 unfiltered "$work/bootstrap.json" > "$work/bad-community"
jq -e '.reliable==true and .universalEligible==true and .nxdomainOk==true and .error==null and .requiredTotalQueries==(.compatibilityTotal*2) and .requiredSuccessCount==.requiredTotalQueries and .communitySelected==4 and .communityProbeTotal>0 and .communityScore<100 and (.communityResults|any(.id=="hdrezka" and .tested==true and .passed==false and (.failures|index("hdrezka.ag"))!=null)) and .communityAdvisory==true and (.warnings|index("community_dns_failed_advisory"))!=null' "$work/bad-community" >/dev/null || fail 'community DNS failure still blocks healthy mandatory baseline/NXDOMAIN or diagnostics lost'
grep -q '^podkop-dns-test.invalid$' "$work/queries" || fail 'community failure skipped positive NXDOMAIN verification'
validate_service_compatibility 127.0.0.42 || fail 'post-apply still makes advisory community domains mandatory'
community_mode=good
benchmark_main_candidate udp cloudflare Cloudflare 1.1.1.1 unfiltered "$work/bootstrap.json" > "$work/good-community"
jq -e --slurpfile bad "$work/bad-community" '.reliable==true and .communityScore==100 and .score>$bad[0].score and (.warnings|length)==0' "$work/good-community" >/dev/null || fail 'community diagnostic score stopped reflecting failures'
for mandatory_fail in play.googleapis.com chatgpt.com api.openai.com; do
    benchmark_main_candidate udp cloudflare Cloudflare 1.1.1.1 unfiltered "$work/bootstrap.json" > "$work/result"
    jq -e --arg failed "$mandatory_fail" '.reliable==false and .universalEligible==false and .error=="service_compatibility_failed" and (.compatibilityFailures|index($failed))!=null' "$work/result" >/dev/null || fail 'mandatory baseline relaxed'
    ! validate_service_compatibility 127.0.0.42 || fail 'post-apply mandatory baseline relaxed'
done
mandatory_fail=none; bad_nx=1
benchmark_main_candidate udp cloudflare Cloudflare 1.1.1.1 unfiltered "$work/bootstrap.json" > "$work/result"
jq -e '.reliable==false and .universalEligible==false and .error=="nxdomain_check_failed"' "$work/result" >/dev/null || fail 'NXDOMAIN gate relaxed'
bad_nx=0; community_mode=unstable; : > "$work/queries"
benchmark_main_candidate udp cloudflare Cloudflare 1.1.1.1 unfiltered "$work/bootstrap.json" > "$work/result"
jq -e '.reliable==true and .universalEligible==true and .communityScore<100 and (.communityResults|any(.stable==false and (.unstable|length)>0)) and (.warnings|index("community_dns_unstable_advisory"))!=null' "$work/result" >/dev/null || fail 'unstable advisory diagnostics not honest'
echo 'PASS: community diagnostics advisory with rows/score/warnings retained; mandatory Play/ChatGPT/API and NXDOMAIN unchanged'
