# subscription_services_v1 begin
# subscription_gemini_region_v2
# Public website diagnostics only: no API keys, cookies or production selectors.
subscription_services_catalog() {
    printf '%s\n' '[{"id":"gemini","label":"Gemini Web","proof":"preliminary_or_manual"},{"id":"chatgpt","label":"ChatGPT Web","proof":"preliminary_or_manual"},{"id":"exit_country","label":"Exit country matches name","proof":"dual_provider_geo"},{"id":"google_country","label":"Google country matches name","proof":"google_region"}]'
}

subscription_services_validate() {
    printf '%s' "$1" | jq -e 'type=="array" and length<=4 and all(.[]; .=="gemini" or .=="chatgpt" or .=="exit_country" or .=="google_country") and length==(unique|length)' >/dev/null 2>&1
}

subscription_required_services_json() {
    local values
    values="$(subscription_tags_json "$1" subscription_required_services)" || return 1
    subscription_services_validate "$values" || return 1
    printf '%s\n' "$values"
}

subscription_services_context() {
    local udp='' dns settings
    config_get udp "$1" enable_udp_over_tcp
    # DNS/profile changes invalidate observations, but changing the working selector does not.
    dns="$(jq -ceS '.dns | select(type=="object" and (.servers|type=="array"))' /etc/sing-box/config.json)" || return 1
    settings="$(uci -q show podkop.settings)" || return 1
    # Bind desired DNS settings too, so edits before a runtime rebuild cannot reuse old checks.
    settings="$(printf '%s\n' "$settings" | sed '/^podkop.settings.shutdown_correctly=/d; /^podkop.settings.subscription_isolated_section=/d' | LC_ALL=C sort)"
    { printf '%s\n' "$dns" "$settings"; printf '%s\n' "service-web-v2:$udp"; } | sha256sum | awk '{print $1}'
}

subscription_services_cache_path() {
    printf '%s/%s.json\n' "${PODKOP_SERVICE_CACHE_DIR:-/etc/podkop/subscriptions/service-checks}" "$1"
}

subscription_services_read() {
    local section="$1" context now path
    context="$(subscription_services_context "$section")" || return 1
    [ -n "$context" ] || return 1
    now="$(date +%s)"; path="$(subscription_services_cache_path "$section")"
    if [ -s "$path" ] && [ "$(wc -c < "$path")" -le 2097152 ]; then
        jq -c --arg context "$context" --argjson now "$now" --argjson country_map "$(subscription_services_country_map)" '
            def fresh:
                (.checkedAt|type=="number") and .checkedAt>0 and .checkedAt<=$now
                and (.expiresAt|type=="number") and .expiresAt>$now and .expiresAt<=(.checkedAt+86400);
            if .context==$context then [.results[]? | select(fresh) | . as $row
                | .services |= (with_entries(select((.key!="google_country" and .key!="exit_country") or (.value | fresh)))
                    | with_entries(.value |= (
                    . + {checkedAt:(.checkedAt // $row.checkedAt),expiresAt:(.expiresAt // $row.expiresAt)}))
                    | with_entries(select(.value | fresh))
                    | with_entries(select(.key!="exit_country" or (.value |
                        .proofVersion==1 and .manual==false and (.declaredName|type=="string")
                        and (.state=="pass" or .state=="fail" or .state=="unknown")
                        and (.observations|type=="array" and length==2
                            and (map(.provider)|sort)==["ipinfo","ipwhois"])
                        and (if .state=="pass" then . as $proof
                            | .network=="pass" and (.declaredCountry|type=="string" and length==2)
                            and .exitCountry==.declaredCountry
                            and all(.observations[]; .valid==true and .country==$proof.exitCountry)
                          else true end))))
                    | with_entries(select(.key!="google_country" or (.value |
                        .proofVersion==1 and .manual==false and (.declaredName|type=="string")
                        and (.state=="pass" or .state=="fail" or .state=="unknown")
                        and (if .state=="pass" or .state=="fail" then . as $proof
                            | .network=="pass" and .httpCode==200
                            and (.declaredCountry|type=="string" and length==2)
                            and (.googleCountry|type=="string" and length==2)
                            and (.region|type=="string" and length==3)
                            and $country_map[$proof.region]==$proof.googleCountry
                            and $country_map[$proof.googleCountry]==$proof.region
                            and (if .state=="pass" then .googleCountry==.declaredCountry
                                 else .googleCountry!=.declaredCountry end)
                          else true end)))))
                | select(.services|length>0)] else [] end
        ' "$path" 2>/dev/null || printf '[]\n'
    else printf '[]\n'; fi
}

subscription_services_policy() {
    local required results
    required="${2:-}"
    [ -n "$required" ] || required="$(subscription_required_services_json "$1")" || return 1
    subscription_services_validate "$required" || return 1
    if [ "$required" = '[]' ]; then results='[]'; else results="$(subscription_services_read "$1")" || return 1; fi
    printf '%s\n' "$results" | jq -c --argjson required "$required" '{required:$required,results:.}'
}

get_subscription_services() {
    local section="$1" required results
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || { subscription_services_error invalid_section; return 1; }
    required="$(subscription_required_services_json "$section")" || { subscription_services_error invalid_required_services; return 1; }
    results="$(subscription_services_read "$section")" || { subscription_services_error context_unavailable; return 1; }
    printf '%s\n' "$results" | jq -c --argjson required "$required" --argjson catalog "$(subscription_services_catalog)" \
        '{success:true,requiredServices:$required,catalog:$catalog,results:.,ttl:86400,capacity:2048}'
}

subscription_services_error() {
    jq -cn --arg error "$1" '{success:false,error:$error}'
}

subscription_services_mark_pending() (
    # Only persisted requirements need activation; diagnostics never apply themselves.
    required="$(subscription_required_services_json "$1")" || exit 1
    [ "$required" != '[]' ] || exit 0
    subscription_pending_mark "$1"
)

subscription_services_store() {
    local section="$1" id="$2" services="$3" context now path dir
    validate_subscription_section_name "$section" && validate_subscription_link_id "$id" || return 1
    context="$(subscription_services_context "$section")" || return 1
    [ -n "$context" ] || return 1
    now="$(date +%s)"; path="$(subscription_services_cache_path "$section")"; dir="${path%/*}"
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" || return 1
    # Keep bounded expired observations for exact already-admitted boot snapshot identity.
    # The admission reader still rejects their expiry; this never renews old proof.
    if [ -s "$path" ] && [ "$(wc -c < "$path")" -le 2097152 ]; then
        cat "$path"
    else printf '{}\n'; fi | jq -c --arg context "$context" --arg id "$id" --argjson now "$now" --argjson services "$services" '
    # At most 2048 observations / 2 MiB per section; only public state and opaque IDs.
        (if .context==$context then (.results // []) else [] end) as $previous
        | ($previous | map(select(.id==$id)) | last // {}) as $old
        # Checking a subset never replaces or renews another service observation.
        # Preserve expired raw identity for admitted boot snapshots; read strips stale proof.
        | (($old.services // {}) | with_entries(.value += {
            checkedAt:(.value.checkedAt // $old.checkedAt),expiresAt:(.value.expiresAt // $old.expiresAt)})) as $retained
        | ($services | with_entries(.value += {checkedAt:$now,expiresAt:($now+86400)})) as $checked
        | {context:$context,results:(($previous|map(select(.id!=$id))) + [{id:$id,checkedAt:$now,expiresAt:($now+86400),services:($retained+$checked)}] | .[-2048:])}
    ' > "$path.tmp.$$" || return 1
    if [ ! -s "$path.tmp.$$" ] || [ "$(wc -c < "$path.tmp.$$")" -gt 2097152 ]; then rm -f "$path.tmp.$$"; return 1; fi
    # Stage pending first: a failed marker write must not invalidate admitted evidence.
    if ! chmod 600 "$path.tmp.$$" || ! subscription_services_mark_pending "$section"; then rm -f "$path.tmp.$$"; return 1; fi
    mv "$path.tmp.$$" "$path"
}

subscription_gemini_region_policy() {
    # Snapshot 2026-10-09: Google Gemini *web* availability, not API/mobile availability.
    # https://support.google.com/gemini/answer/13575153?hl=en
    # Marker independently used by Clash Verge Rev crates/clash-verge-media-unlock/src/gemini.rs.
    # Official support conflicts with that checker for HKG/MAC; CHN is Workspace-only.
    # These conditional/conflicting countries and unrecognized tokens need manual proof.
    case "$1" in
        RUS|BLR|CUB|IRN|PRK|SYR) printf 'blocked\n';;
        ALA|ALB|DZA|ASM|AND|AGO|AIA|ATA|ATG|ARG|ARM|ABW|AUS|AUT|AZE|BHR|BGD|BRB|BEL|BLZ|BEN|BMU|BTN|BOL|BIH|BWA|BRA|IOT|VGB|BRN|BGR|BFA|BDI|CPV|KHM|CMR|CAN|BES|CYM|CAF|TCD|CHL|CXR|CCK|COL|COM|COK|CRI|CIV|HRV|CUW|CZE|COD|DNK|DJI|DMA|DOM|ECU|EGY|SLV|GNQ|ERI|EST|SWZ|ETH|FLK|FRO|FJI|FIN|FRA|GUF|PYF|ATF|GAB|GEO|DEU|GHA|GIB|GRC|GRL|GRD|GLP|GUM|GTM|GGY|GIN|GNB|GUY|HTI|HMD|HND|HUN|ISL|IND|IDN|IRQ|IRL|IMN|ISR|ITA|JAM|JPN|JEY|JOR|KAZ|KEN|KIR|XKX|KWT|KGZ|LAO|LVA|LBN|LSO|LBR|LBY|LIE|LTU|LUX|MDG|MWI|MYS|MDV|MLI|MLT|MHL|MTQ|MRT|MUS|MYT|MEX|FSM|MDA|MCO|MNG|MNE|MSR|MAR|MOZ|MMR|NAM|NRU|NPL|NLD|NCL|NZL|NIC|NER|NGA|NIU|NFK|MKD|MNP|NOR|OMN|PAK|PLW|PSE|PAN|PNG|PRY|PER|PHL|PCN|POL|PRT|PRI|QAT|CYP|COG|REU|ROU|RWA|BLM|SHN|KNA|LCA|MAF|SPM|VCT|WSM|SMR|STP|SAU|SEN|SRB|SYC|SLE|SGP|SXM|SVK|SVN|SLB|SOM|ZAF|SGS|KOR|SSD|ESP|LKA|SDN|SUR|SJM|SWE|CHE|TWN|TJK|TZA|THA|BHS|GMB|TLS|TGO|TKL|TON|TTO|TUN|TUR|TKM|TCA|TUV|VIR|UGA|UKR|ARE|GBR|USA|UMI|URY|UZB|VUT|VAT|VEN|VNM|WLF|ESH|YEM|ZMB|ZWE) printf 'supported\n';;
        *) printf 'unknown\n';;
    esac
}

subscription_services_country_pairs() {
    # ISO 3166-1 alpha2:alpha3; not regional pseudo-codes (EU/UK/ZZ/XK).
    printf '%s\n' 'AD:AND AE:ARE AF:AFG AG:ATG AI:AIA AL:ALB AM:ARM AO:AGO AQ:ATA AR:ARG AS:ASM AT:AUT AU:AUS AW:ABW AX:ALA AZ:AZE BA:BIH BB:BRB BD:BGD BE:BEL BF:BFA BG:BGR BH:BHR BI:BDI BJ:BEN BL:BLM BM:BMU BN:BRN BO:BOL BQ:BES BR:BRA BS:BHS BT:BTN BV:BVT BW:BWA BY:BLR BZ:BLZ CA:CAN CC:CCK CD:COD CF:CAF CG:COG CH:CHE CI:CIV CK:COK CL:CHL CM:CMR CN:CHN CO:COL CR:CRI CU:CUB CV:CPV CW:CUW CX:CXR CY:CYP CZ:CZE DE:DEU DJ:DJI DK:DNK DM:DMA DO:DOM DZ:DZA EC:ECU EE:EST EG:EGY EH:ESH ER:ERI ES:ESP ET:ETH FI:FIN FJ:FJI FK:FLK FM:FSM FO:FRO FR:FRA GA:GAB GB:GBR GD:GRD GE:GEO GF:GUF GG:GGY GH:GHA GI:GIB GL:GRL GM:GMB GN:GIN GP:GLP GQ:GNQ GR:GRC GS:SGS GT:GTM GU:GUM GW:GNB GY:GUY HK:HKG HM:HMD HN:HND HR:HRV HT:HTI HU:HUN ID:IDN IE:IRL IL:ISR IM:IMN IN:IND IO:IOT IQ:IRQ IR:IRN IS:ISL IT:ITA JE:JEY JM:JAM JO:JOR JP:JPN KE:KEN KG:KGZ KH:KHM KI:KIR KM:COM KN:KNA KP:PRK KR:KOR KW:KWT KY:CYM KZ:KAZ LA:LAO LB:LBN LC:LCA LI:LIE LK:LKA LR:LBR LS:LSO LT:LTU LU:LUX LV:LVA LY:LBY MA:MAR MC:MCO MD:MDA ME:MNE MF:MAF MG:MDG MH:MHL MK:MKD ML:MLI MM:MMR MN:MNG MO:MAC MP:MNP MQ:MTQ MR:MRT MS:MSR MT:MLT MU:MUS MV:MDV MW:MWI MX:MEX MY:MYS MZ:MOZ NA:NAM NC:NCL NE:NER NF:NFK NG:NGA NI:NIC NL:NLD NO:NOR NP:NPL NR:NRU NU:NIU NZ:NZL OM:OMN PA:PAN PE:PER PF:PYF PG:PNG PH:PHL PK:PAK PL:POL PM:SPM PN:PCN PR:PRI PS:PSE PT:PRT PW:PLW PY:PRY QA:QAT RE:REU RO:ROU RS:SRB RU:RUS RW:RWA SA:SAU SB:SLB SC:SYC SD:SDN SE:SWE SG:SGP SH:SHN SI:SVN SJ:SJM SK:SVK SL:SLE SM:SMR SN:SEN SO:SOM SR:SUR SS:SSD ST:STP SV:SLV SX:SXM SY:SYR SZ:SWZ TC:TCA TD:TCD TF:ATF TG:TGO TH:THA TJ:TJK TK:TKL TL:TLS TM:TKM TN:TUN TO:TON TR:TUR TT:TTO TV:TUV TW:TWN TZ:TZA UA:UKR UG:UGA UM:UMI US:USA UY:URY UZ:UZB VA:VAT VC:VCT VE:VEN VG:VGB VI:VIR VN:VNM VU:VUT WF:WLF WS:WSM YE:YEM YT:MYT ZA:ZAF ZM:ZMB ZW:ZWE'
}

subscription_services_country_map() {
    subscription_services_country_pairs | jq -Rc 'split(" ") | map(split(":"))
        | reduce .[] as $pair ({}; .[$pair[0]]=$pair[1] | .[$pair[1]]=$pair[0])'
}

subscription_services_google_region() {
    local rc="$1" code="$2" body="$3" network=pass reason=region_marker_missing region='' country='' tokens normalized
    if [ "$rc" -ne 0 ]; then network=fail; reason=network_failed
    elif [ "$code" != 200 ]; then
        case "$code" in 401|403|404|429) reason=challenge_required;; *) network=fail; reason=http_failed;; esac
    elif printf '%s' "$body" | grep -Eiq 'unusual traffic|captcha|cf-chl-|access denied'; then reason=challenge_required
    elif ! printf '%s' "$body" | grep -Eiq '<html([[:space:]>])|<!doctype[[:space:]]+html([[:space:]>])'; then reason=invalid_response
    elif ! printf '%s' "$body" | grep -iq 'Gemini'; then reason=invalid_response
    else
        # Complete quoted ISO2/ISO3 markers only; unknown tokens contaminate rather
        # than disappearing beside a valid marker. Equivalent ISO2/ISO3 is one country.
        tokens="$(printf '%s' "$body" | grep -Eo ',2,1,200,"[A-Z]{2,3}"' | sed 's/^,2,1,200,"//;s/"$//' | LC_ALL=C sort -u)"
        if [ -n "$tokens" ]; then
            normalized="$(printf '%s\n' "$tokens" | jq -Rsc --argjson countries "$(subscription_services_country_map)" '
                split("\n") | map(select(length>0))
                | map(if $countries[.]==null then null elif length==2 then $countries[.] else . end) | unique')" || return 1
            if printf '%s' "$normalized" | jq -e 'length==1 and .[0]!=null' >/dev/null; then
                region="$(printf '%s' "$normalized" | jq -r '.[0]')"
                country="$(subscription_services_country_map | jq -r --arg region "$region" '.[$region]')"
                reason=region_observed
            elif printf '%s' "$normalized" | jq -e 'length>1' >/dev/null; then reason=region_marker_ambiguous
            else reason=region_unknown; fi
        fi
    fi
    jq -cn --arg network "$network" --arg reason "$reason" --arg code "$code" --arg region "$region" --arg country "$country" '
        {network:$network,reason:$reason,httpCode:($code|tonumber? // 0),
         region:(if $region=="" then null else $region end),googleCountry:(if $country=="" then null else $country end)}'
}

subscription_services_google_country_classify() {
    local name="$1" rc="$2" code="$3" body="$4" observation declaration
    observation="$(subscription_services_google_region "$rc" "$code" "$body")" || return 1
    declaration="$(subscription_exit_country_declaration "$name")" || return 1
    printf '%s' "$observation" | jq -c --arg name "$name" --argjson declaration "$declaration" '
        . + {proofVersion:1,manual:false,declaredName:$name,declaredCountry:$declaration.country,
             observationReason:.reason,
             state:(if $declaration.country==null or .googleCountry==null then "unknown"
                    elif $declaration.country==.googleCountry then "pass" else "fail" end),
             reason:(if $declaration.country==null then
                        (if $declaration.reason=="exit_country_declared_ambiguous" then "google_country_declared_ambiguous" else "google_country_declared_missing" end)
                     elif .googleCountry==null then "google_country_unavailable"
                     elif $declaration.country==.googleCountry then "google_country_match" else "google_country_mismatch" end)}'
}

subscription_exit_country_codes() {
    # ISO 3166-1 alpha-2, not regional pseudo-codes (EU/UK/ZZ/XK).
    printf '%s\n' 'AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW'
}

subscription_exit_country_declaration() {
    jq -cn --arg name "$1" --arg codes "$(subscription_exit_country_codes)" '
        ($codes|split(" ")) as $iso
        | ($name|explode) as $chars
        | [range(0; (($chars|length)-1)) | . as $i
            | select(all($chars[$i:$i+2][]; .>=127462 and .<=127487))
            | [$chars[$i:$i+2][]|.-127397]|implode] as $flags
        | (if ($chars|length)>=2 and all($chars[0:2][]; .>=65 and .<=90)
            and (($chars|length)==2 or ([" ","\t","\n","\r","\f",".","_",":","/","-"]|index($name[2:3])!=null))
            then [$name[0:2]] else [] end) as $leading
        | ($flags+$leading|unique) as $candidates
        | {country:(if ($candidates|length)==1 and ($iso|index($candidates[0]))!=null then $candidates[0] else null end),
           reason:(if ($candidates|length)>1 then "exit_country_declared_ambiguous" else "exit_country_declared_missing" end)}
    '
}

subscription_exit_country_declared() {
    subscription_exit_country_declaration "$1" | jq -r '.country // empty'
}

subscription_exit_country_public_ip() {
    # Strict syntax, then conservative global-unicast scope. Unfamiliar/special ranges
    # cannot create a pass. Embedded/mapped IPv4 forms intentionally remain unknown.
    jq -en --arg ip "$1" '
        def decimal:
            length>0 and all(explode[]; .>=48 and .<=57)
            and (length==1 or (startswith("0")|not));
        def hexnum:
            ascii_downcase|explode
            | if length>0 and length<=4 and all(.[]; (.>=48 and .<=57) or (.>=97 and .<=102))
              then reduce .[] as $c (0; .*16+(if $c<=57 then $c-48 else $c-87 end)) else null end;
        if ($ip|contains(":")) then
            ($ip|ascii_downcase|split("::")) as $halves
            | (if ($halves|length)==1 then ($ip|split(":"))
               elif ($halves|length)==2 then
                   (if $halves[0]=="" then [] else ($halves[0]|split(":")) end) as $left
                   | (if $halves[1]=="" then [] else ($halves[1]|split(":")) end) as $right
                   | if ($left|length)+($right|length)<8 then
                       $left+[range(0;8-($left|length)-($right|length))|"0"]+$right else [] end
               else [] end) as $parts
            | ($parts|map(hexnum)) as $groups
            | ($groups|length)==8 and all($groups[]; .!=null)
                and $groups[0]>=8192 and $groups[0]<=16383
                and ($groups[0]!=8193 or ($groups[1]>511 and $groups[1]!=3512))
                and $groups[0]!=8194 and $groups[0]<16382
        else
            ($ip|split(".")) as $parts
            | if ($parts|length)==4 and all($parts[]; decimal) then
                ($parts|map(tonumber)) as $octets
                | all($octets[]; .>=0 and .<=255)
                  and $octets[0]>0 and $octets[0]<224 and $octets[0]!=10 and $octets[0]!=127
                  and ($octets[0]!=100 or $octets[1]<64 or $octets[1]>127)
                  and ($octets[0]!=169 or $octets[1]!=254)
                  and ($octets[0]!=172 or $octets[1]<16 or $octets[1]>31)
                  and ($octets[0]!=192 or ($octets[1]!=168
                    and ($octets[1]!=0 or ($octets[2]!=0 and $octets[2]!=2))
                    and ($octets[1]!=88 or $octets[2]!=99)))
                  and ($octets[0]!=198 or (($octets[1]!=18 and $octets[1]!=19)
                    and ($octets[1]!=51 or $octets[2]!=100)))
                  and ($octets[0]!=203 or $octets[1]!=0 or $octets[2]!=113)
              else false end
        end
    ' >/dev/null 2>&1
}

subscription_exit_country_observation() {
    local provider="$1" rc="$2" code="$3" body="$4" ip='' country='' valid=false reason=invalid_response fields
    case "$provider" in ipwhois|ipinfo) ;; *) return 1;; esac
    if [ "$rc" -ne 0 ]; then reason=network_failed
    elif [ "$code" != 200 ]; then reason=http_failed
    else
        fields="$(printf '%s' "$body" | jq -er --arg provider "$provider" '
            select(type=="object" and (.ip|type=="string") and .bogon!=true
                and (if $provider=="ipwhois" then .success==true and (.country_code|type=="string") else (.country|type=="string") end))
            | [.ip,(if $provider=="ipwhois" then .country_code else .country end)]|@tsv' 2>/dev/null)" || fields=''
        if [ -n "$fields" ]; then
            ip="${fields%%	*}"; country="${fields#*	}"
            case "$country" in
                [A-Z][A-Z])
                    case " $(subscription_exit_country_codes) " in
                        *" $country "*)
                            if subscription_exit_country_public_ip "$ip"; then valid=true; reason=observed; else reason=non_public_ip; fi;;
                        *) reason=invalid_country;;
                    esac;;
                *) reason=invalid_country;;
            esac
        fi
    fi
    jq -cn --arg provider "$provider" --arg ip "$ip" --arg country "$country" --arg code "$code" --arg reason "$reason" --argjson valid "$valid" \
        '{provider:$provider,valid:$valid,reason:$reason,ip:(if $ip=="" then null else $ip end),country:(if $country=="" then null else $country end),httpCode:($code|tonumber? // 0)}'
}

subscription_exit_country_classify() {
    local declared="$1" name="$2" observations="$3" declaration
    declaration="$(subscription_exit_country_declaration "$name")" || return 1
    printf '%s' "$observations" | jq -c --arg declared "$declared" --arg name "$name" --argjson declaration "$declaration" '
        . as $observations
        | (length==2 and (map(.provider)|sort)==["ipinfo","ipwhois"] and all(.[]; .valid==true)) as $valid
        | ($valid and .[0].country==.[1].country) as $agreement
        | {state:(if $declared=="" or ($agreement|not) then "unknown" elif .[0].country==$declared then "pass" else "fail" end),
           network:(if $valid then "pass" else "fail" end),
           reason:(if $declared=="" then $declaration.reason elif ($valid|not) then "exit_country_unavailable"
             elif ($agreement|not) then "exit_country_sources_disagree" elif .[0].country==$declared then "exit_country_match" else "exit_country_mismatch" end),
           manual:false,proofVersion:1,declaredName:$name,
           declaredCountry:(if $declared=="" then null else $declared end),
           exitCountry:(if $agreement then .[0].country else null end),observations:$observations}
    '
}

subscription_exit_country_probe() {
    local section="$1" id="$2" proxy="$3" work="$4" name declared provider url rc code observation observations='[]'
    name="$(jq -er --arg id "$id" '.[] | select(.id==$id) | (.name // .tag // "")' "$(get_subscription_items_cache_path "$section")")" || return 1
    declared="$(subscription_exit_country_declared "$name")" || return 1
    for provider in ipwhois ipinfo; do
        case "$provider" in
            ipwhois) url='https://ipwho.is/?fields=success,ip,country_code';;
            ipinfo) url='https://ipinfo.io/json';;
        esac
        rc=0
        # Two independent HTTPS observations through this exact isolated node only.
        # Track the child in the caller shell, preserving signal cleanup ownership.
        curl -sS --proto '=https' --proto-redir '=https' --proxy "$proxy" --noproxy '' --connect-timeout 2 -m 4 --retry 0 \
            --max-filesize 16384 -o "$work/geo.body" -w '%{http_code}' "$url" > "$work/geo.code" 2>"$work/geo.error" &
        curl_pids=$!; wait "$curl_pids" || rc=$?; curl_pids=''
        code="$(cat "$work/geo.code")"
        observation="$(subscription_exit_country_observation "$provider" "$rc" "$code" "$(head -c 16384 "$work/geo.body" 2>/dev/null)")" || return 1
        observations="$(printf '%s' "$observations" | jq -c --argjson observation "$observation" '.+[$observation]')" || return 1
    done
    SUBSCRIPTION_EXIT_COUNTRY_RESULT="$(subscription_exit_country_classify "$declared" "$name" "$observations")"
}

subscription_services_google_probe() {
    local section="$1" id="$2" proxy="$3" work="$4" name rc=0 code body
    name="$(jq -er --arg id "$id" '[.[] | select(.id==$id)] | select(length==1) | .[0] | (.name // .tag // "") | select(type=="string")' "$(get_subscription_items_cache_path "$section")")" || return 1
    # One verified, bounded HTTPS observation feeds two independent policies.
    # Prefetching prevents another service failure from suppressing Google proof.
    curl -sS -L --proto '=https' --proto-redir '=https' --max-redirs 3 --proxy "$proxy" --noproxy '' \
        -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' -H 'Accept-Language: en-US,en;q=0.9' \
        --connect-timeout 2 -m 4 --retry 0 --max-filesize 1048576 -o "$work/google.body" -w '%{http_code}' https://gemini.google.com/ > "$work/google.code" 2>"$work/google.error" &
    curl_pids=$!; wait "$curl_pids" || rc=$?; curl_pids=''
    code="$(cat "$work/google.code")"; body="$(head -c 1048576 "$work/google.body" 2>/dev/null)"
    SUBSCRIPTION_GOOGLE_COUNTRY_RESULT="$(subscription_services_google_country_classify "$name" "$rc" "$code" "$body")" || return 1
    SUBSCRIPTION_GOOGLE_GEMINI_RESULT="$(subscription_services_classify gemini "$rc" "$code" "$body")" || return 1
}

subscription_services_classify() {
    local service="$1" rc="$2" code="$3" body="$4" state=unknown network=pass reason=confirmation_required region='' tokens policy
    case "$service" in gemini|chatgpt) ;; *) return 1;; esac
    case "$code" in 2??) ;; 401|403|404|429) state=unknown; reason=challenge_required;; *) network=fail; state=fail; reason=http_failed;; esac
    if [ "$rc" -ne 0 ]; then network=fail; state=fail; reason=network_failed; fi
    if [ "$service" = gemini ]; then
        # A transport/HTTP failure cannot establish geographic eligibility or denial.
        state=unknown
        if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && printf '%s' "$body" | grep -Eiq '<html([[:space:]>])|<!doctype[[:space:]]+html([[:space:]>])' && printf '%s' "$body" | grep -iq 'Gemini'; then
            if printf '%s' "$body" | grep -Eiq 'unusual traffic|captcha|cf-chl-|access denied'; then
                reason=challenge_required
            else
                # Match a complete quoted ISO3 token; conflicting countries are ambiguous.
                tokens="$(printf '%s' "$body" | grep -Eo ',2,1,200,"[A-Z]{3}"' | sed 's/^,2,1,200,"//;s/"$//' | LC_ALL=C sort -u)"
                case "$tokens" in
                    '') reason=region_marker_missing;;
                    [A-Z][A-Z][A-Z]) region="$tokens"; reason=region_unknown;;
                    *) reason=region_marker_ambiguous;;
                esac
                if [ -n "$region" ]; then
                    policy="$(subscription_gemini_region_policy "$region")"
                    case "$policy" in
                        supported) state=pass; reason=region_precheck_passed;;
                        blocked) state=fail; reason=region_denied;;
                    esac
                fi
            fi
        elif [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -Eiq 'unusual traffic|captcha|cf-chl-|access denied'; then
            reason=challenge_required
        fi
    else
        if [ "$rc" -eq 0 ] && [ "$code" = 200 ] && printf '%s' "$body" | jq -e 'type=="object" and (.models|type=="array" and length>0 and all(.[]; type=="object" and ((.slug // .id)|type=="string" and length>0)))' >/dev/null 2>&1; then
            state=pass; reason=anonymous_models_available
        fi
        if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -Eiq 'unusual traffic|captcha|cf-chl-|access denied'; then
            state=unknown; reason=challenge_required
        fi
        if [ "$rc" -eq 0 ] && printf '%s' "$body" | grep -Eiq 'not (available|supported) in (your|this) (country|region)|unsupported[ _](country|region)'; then
            state=fail; network=fail; reason=region_denied
        fi
    fi
    jq -cn --arg state "$state" --arg network "$network" --arg reason "$reason" --arg code "$code" --arg region "$region" \
        '{state:$state,network:$network,reason:$reason,httpCode:($code|tonumber? // 0),manual:false,region:(if $region=="" then null else $region end)}'
}

subscription_services_probe() {
    local section="$1" id="$2" services="$3" proxy="$4" work="$5" service url rc code value results='{}' failed=0 google_results=0
    printf '%s' "$services" | jq -r '.[]' > "$work/services.list" || return 1
    if printf '%s' "$services" | jq -e 'index("google_country")!=null' >/dev/null; then
        subscription_services_google_probe "$section" "$id" "$proxy" "$work" || return 1
        google_results=1
    fi
    while IFS= read -r service; do
        if [ "$google_results" = 1 ]; then
            case "$service" in
                google_country) value="$SUBSCRIPTION_GOOGLE_COUNTRY_RESULT";;
                gemini) value="$SUBSCRIPTION_GOOGLE_GEMINI_RESULT"
                    if printf '%s' "$value" | jq -e '.state=="fail"' >/dev/null; then failed=1; fi;;
                *) value='';;
            esac
            if [ -n "$value" ]; then
                results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
                continue
            fi
        fi
        if [ "$service" = exit_country ]; then
            # Geography remains independently observable even if a web probe failed.
            subscription_exit_country_probe "$section" "$id" "$proxy" "$work" || return 1
            value="$SUBSCRIPTION_EXIT_COUNTRY_RESULT"
            results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
            continue
        fi
        if [ "$failed" = 1 ]; then
            value='{"state":"unknown","network":"fail","reason":"skipped_after_failure","httpCode":0,"manual":false}'
            results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
            continue
        fi
        case "$service" in
            gemini) url=https://gemini.google.com/;;
            chatgpt) url=https://chatgpt.com/backend-anon/models;;
            *) return 1;;
        esac
        # TLS remains verified. Redirects restricted to HTTPS; bodies are temporary/private.
        rc=0
        curl -sS -L --proto '=https' --proto-redir '=https' --max-redirs 3 --proxy "$proxy" --noproxy '' \
            -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36' -H 'Accept-Language: en-US,en;q=0.9' \
            --connect-timeout 2 -m 4 --retry 0 --max-filesize 1048576 -o "$work/service.body" -w '%{http_code}' "$url" > "$work/service.code" 2>"$work/service.error" &
        curl_pids=$!; wait "$curl_pids" || rc=$?; curl_pids=''
        code="$(cat "$work/service.code")"
        value="$(subscription_services_classify "$service" "$rc" "$code" "$(head -c 1048576 "$work/service.body" 2>/dev/null)")" || return 1
        if printf '%s' "$value" | jq -e '.state=="fail"' >/dev/null; then failed=1; fi
        results="$(printf '%s' "$results" | jq -c --arg service "$service" --argjson value "$value" '.[$service]=$value')" || return 1
    done < "$work/services.list"
    subscription_services_store "$section" "$id" "$results" || return 1
    jq -cn --arg id "$id" --argjson services "$results" '{success:true,id:$id,services:$services}'
}

subscription_services_check() {
    subscription_services_validate "${3:-}" && [ "$3" != '[]' ] || { subscription_services_error invalid_services; return 1; }
    subscription_isolated_test "$1" "$2" services "$3"
}

subscription_services_confirm() (
    section="$1"; id="$2"; service="$3"; enabled="$4"; locked=0
    trap '[ "$locked" = 0 ] || subscription_action_lock_release' EXIT
    trap 'exit 130' INT TERM HUP
    validate_subscription_section_name "$section" && validate_subscription_urltest_section "$section" || { subscription_services_error invalid_section; exit 1; }
    validate_subscription_link_id "$id" || { subscription_services_error invalid_link_id; exit 1; }
    case "$service:$enabled" in gemini:true|chatgpt:true|gemini:false|chatgpt:false) ;; *) subscription_services_error invalid_confirmation; exit 1;; esac
    subscription_runtime_busy && { subscription_services_error service_busy; exit 1; }
    subscription_action_lock_acquire service_confirmation || { subscription_services_error service_busy; exit 1; }; locked=1
    jq -e --arg id "$id" 'any(.[]; .id==$id and .supported)' "$(get_subscription_items_cache_path "$section")" >/dev/null 2>&1 || { subscription_services_error subscription_link_not_available; exit 1; }
    results="$(subscription_services_read "$section")" || exit 1
    row="$(printf '%s' "$results" | jq -c --arg id "$id" '.[] | select(.id==$id)')"
    printf '%s' "$row" | jq -e --arg service "$service" '.services[$service].network=="pass"' >/dev/null 2>&1 || { subscription_services_error recent_network_check_required; exit 1; }
    if [ "$enabled" = true ] && ! printf '%s' "$row" | jq -e --arg service "$service" '.services[$service].state=="unknown"' >/dev/null; then
        subscription_services_error confirmation_requires_unknown_state
        exit 1
    fi
    # Confirmation cannot extend the underlying network observation's expiry.
    path="$(subscription_services_cache_path "$section")"
    jq --arg id "$id" --arg service "$service" --argjson enabled "$enabled" '
        .results |= map(if .id==$id then .services[$service] |= (.state=(if $enabled then "pass" else "fail" end) | .manual=true | .reason="user_confirmed") else . end)
    ' "$path" > "$path.tmp.$$" && chmod 600 "$path.tmp.$$" || { rm -f "$path.tmp.$$"; exit 1; }
    subscription_services_mark_pending "$section" || { rm -f "$path.tmp.$$"; subscription_services_error pending_write_failed; exit 1; }
    mv "$path.tmp.$$" "$path" || exit 1
    jq -cn --arg id "$id" --arg service "$service" --argjson enabled "$enabled" '{success:true,id:$id,service:$service,confirmed:$enabled}'
)

# Fail before stopping an existing daemon. Expiry does not trigger a background apply.
subscription_services_preflight_section() {
    local section="$1" required work items all disabled excluded
    validate_subscription_urltest_section "$section" || return 0
    required="$(subscription_required_services_json "$section")" || { SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1; return 0; }
    [ "$required" != '[]' ] || return 0
    work="$(mktemp -d)" || { SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1; return 0; }
    if command -v collect_urltest_proxy_links >/dev/null 2>&1 && collect_urltest_proxy_links "$section" "$work/manual" && [ -s "$work/manual" ]; then
        SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1
        rm -rf "$work"; return 0
    fi
    items="$(get_subscription_items_cache_path "$section")"; all="$(get_subscription_all_cache_path "$section")"
    disabled="$(subscription_disabled_sources_json "$section")"
    excluded='[]'
    if command -v collect_subscription_excluded_ids >/dev/null 2>&1; then
        collect_subscription_excluded_ids "$section" "$work/excluded"
        excluded="$(jq -Rsc 'split("\n") | map(select(length>0))' "$work/excluded")"
    fi
    if ! cp "$items" "$work/items" || ! subscription_filter_source_links "$work/items" "$all" "$work/links" "$disabled" "$excluded" "$section" || [ ! -s "$work/links" ]; then
        SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=1
    fi
    rm -rf "$work"
}

subscription_services_preflight() {
    SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED=0
    config_foreach subscription_services_preflight_section section
    if [ "$SUBSCRIPTION_SERVICES_PREFLIGHT_FAILED" != 0 ]; then
        log 'Required-service evidence is unavailable or expired; retaining the working runtime' warn
        return 1
    fi
}
# subscription_services_v1 end
