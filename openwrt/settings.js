"use strict";
"require form";
"require uci";
"require fs";
"require baseclass";
"require tools.widgets as widgets";
"require view.podkop.main as main";
"require view.podkop.dns_benchmark as dnsBenchmark";

const DNS_OPTIMIZER_COMMAND = "/usr/bin/podkop-dns-optimizer";
const DNS_PRIMARY_POLICY = {
  yandex: { primaryEligible: false },
};
const NORMAL_DNS_OPTIMIZER_CANDIDATES = [
  ["cloudflare","Cloudflare"],
  ["google","Google"],
  ["quad9","Quad9 Secure"],
  ["quad9_ecs","Quad9 Secure ECS"],
  ["adguard_unfiltered","AdGuard Unfiltered"],
  ["controld_unfiltered","Control D Unfiltered"],
  ["mullvad","Mullvad"],
  ["223_5_5_5","223.5.5.5 (AliDNS)"],
  ["223_6_6_6","223.6.6.6 (AliDNS)"],
  ["193_233_112_67","193.233.112.67 (GeoHide Primary)"],
  ["193_233_112_68","193.233.112.68 (GeoHide Secondary)"],
  ["95_182_120_241","95.182.120.241 (GeoHide Third)"],
  ["45_90_28_0","45.90.28.0 (NextDNS Primary)"],
  ["45_90_30_0","45.90.30.0 (NextDNS Secondary)"],
  ["80_253_249_40","80.253.249.40 (dns.malw.link)"],
  ["95_216_204_218","95.216.204.218 (dns.malw.link)"],
  ["149_112_112_112","149.112.112.112 (Quad9)"],
  ["149_112_112_11","149.112.112.11 (Quad9 ECS)"],
  ["9_9_9_10","9.9.9.10 (Quad9 Unsecured)"],
  ["149_112_112_10","149.112.112.10 (Quad9 Unsecured)"],
  ["adguard_default","AdGuard Default"],
  ["adguard_family","AdGuard Family"],
  ["alidns","AliDNS"],
  ["comss","Comss.one"],
  ["geohide","GeoHide"],
  ["geohide_eu","GeoHide Europe"],
  ["geohide_us","GeoHide USA"],
  ["malw","dns.malw.link"],
  ["quad9_unsecured","Quad9 Unsecured"],
  ["nextdns","NextDNS"],
  ["uncensored_anycast","UncensoredDNS Anycast"],
  ["uncensored_unicast","UncensoredDNS Unicast"],
  ["xbox_dns","Xbox DNS"],
];
const DEFAULT_NORMAL_DNS_OPTIMIZER_CANDIDATES = [
  "cloudflare",
  "google",
  "controld_unfiltered",
];
const BOOTSTRAP_DNS_OPTIMIZER_CANDIDATES = [
  ["cloudflare_1","Cloudflare — 1.1.1.1"],
  ["cloudflare_2","Cloudflare — 1.0.0.1"],
  ["google_1","Google — 8.8.8.8"],
  ["google_2","Google — 8.8.4.4"],
  ["yandex_1","Yandex — 77.88.8.8"],
  ["yandex_2","Yandex — 77.88.8.1"],
  ["quad9_1","Quad9 Secure — 9.9.9.9"],
  ["quad9_ecs","Quad9 Secure ECS — 9.9.9.11"],
  ["adguard_unfiltered","AdGuard Unfiltered — 94.140.14.140"],
  ["controld_unfiltered","Control D Unfiltered — 76.76.2.0"],
  ["223_5_5_5","223.5.5.5 (AliDNS)"],
  ["223_6_6_6","223.6.6.6 (AliDNS)"],
  ["193_233_112_67","193.233.112.67 (GeoHide Primary)"],
  ["193_233_112_68","193.233.112.68 (GeoHide Secondary)"],
  ["95_182_120_241","95.182.120.241 (GeoHide Third)"],
  ["45_90_28_0","45.90.28.0 (NextDNS Primary)"],
  ["45_90_30_0","45.90.30.0 (NextDNS Secondary)"],
  ["76_76_10_0","76.76.10.0 (ControlD DNS)"],
  ["80_253_249_40","80.253.249.40 (dns.malw.link DNS)"],
  ["95_216_204_218","95.216.204.218 (dns.malw.link DNS)"],
  ["149_112_112_112","149.112.112.112 (Quad9 DNS)"],
  ["149_112_112_11","149.112.112.11 (Quad9 ECS DNS)"],
  ["9_9_9_10","9.9.9.10 (Quad9 Unsecured DNS)"],
  ["149_112_112_10","149.112.112.10 (Quad9 Unsecured DNS)"],
  ["208_67_222_222","208.67.222.222 (OpenDNS)"],
];
const DEFAULT_BOOTSTRAP_DNS_OPTIMIZER_CANDIDATES = [
  "cloudflare_1",
  "cloudflare_2",
  "google_1",
  "google_2",
  "yandex_1",
  "yandex_2",
  "controld_unfiltered",
];
const dnsOptimizerState = {
  node: null,
  status: null,
  protocolOption: null,
  benchmarkProtocolsOption: null,
  dnsServerOption: null,
  bootstrapDnsServerOption: null,
  failoverEnabledOption: null,
  secondaryProtocolOption: null,
  secondaryDnsServerOption: null,
  secondaryBootstrapDnsServerOption: null,
  pollTimer: null,
  syncedOperation: null,
  historyOpen: false,
  applyingCandidateKey: null,
};

function injectDnsOptimizerStyles() {
  if (document.getElementById("pdk-dns-optimizer-styles")) {
    return;
  }

  const style = document.createElement("style");
  style.id = "pdk-dns-optimizer-styles";
  style.textContent = `
    .pdk-dns-optimizer {
      border: 1px solid var(--border-color-medium, #334155);
      border-radius: 6px;
      box-sizing: border-box;
      width: 100%;
      max-width: 100%;
      padding: 14px;
      margin: 4px 0 12px;
      min-width: 0;
      overflow: hidden;
    }
    .cbi-value[id$="-_dns_optimizer"] {
      display: block;
      min-width: 0;
    }
    .cbi-value[id$="-_dns_optimizer"] > div {
      box-sizing: border-box;
      width: 100%;
      max-width: 100%;
      min-width: 0;
    }
    .pdk-dns-optimizer__header,
    .pdk-dns-optimizer__actions,
    .pdk-dns-optimizer__pair {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
    }
    .pdk-dns-optimizer__header {
      justify-content: space-between;
      margin-bottom: 8px;
    }
    .pdk-dns-optimizer__title {
      font-weight: 700;
      font-size: 15px;
    }
    .pdk-dns-optimizer__description,
    .pdk-dns-optimizer__detail,
    .pdk-dns-optimizer__status {
      color: var(--text-color-secondary, #a8b3c7);
      line-height: 1.45;
    }
    .pdk-dns-optimizer__status {
      min-height: 22px;
      margin: 8px 0 4px;
    }
    .pdk-dns-optimizer__progress {
      height: 4px;
      overflow: hidden;
      background: rgba(127, 127, 127, 0.2);
      border-radius: 2px;
      margin-bottom: 10px;
    }
    .pdk-dns-optimizer__progress > span {
      display: block;
      height: 100%;
      background: #5f9df7;
      transition: width 180ms ease;
    }
    .pdk-dns-optimizer__recommendation {
      border: 1px solid rgba(46, 189, 133, 0.45);
      border-left: 4px solid #2ebd85;
      border-radius: 6px;
      padding: 12px;
      margin: 10px 0;
      background: rgba(46, 189, 133, 0.08);
    }
    .pdk-dns-optimizer__recommendation-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 12px;
      flex-wrap: wrap;
      margin-bottom: 10px;
    }
    .pdk-dns-optimizer__recommendation-title {
      font-size: 16px;
      font-weight: 700;
    }
    .pdk-dns-optimizer__recommendation-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .pdk-dns-optimizer__recommendation-card {
      min-width: 0;
      padding: 10px;
      border: 1px solid rgba(127, 127, 127, 0.25);
      border-radius: 6px;
      background: rgba(15, 23, 42, 0.18);
    }
    .pdk-dns-optimizer__recommendation-card--primary {
      border-color: rgba(46, 189, 133, 0.55);
    }
    .pdk-dns-optimizer__recommendation-role {
      color: var(--text-color-secondary, #a8b3c7);
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    .pdk-dns-optimizer__recommendation-endpoint {
      margin-top: 5px;
      font-size: 15px;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .pdk-dns-optimizer__recommendation-bootstrap {
      margin-top: 5px;
      overflow-wrap: anywhere;
    }
    .pdk-dns-optimizer__recommendation-metrics {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      margin-top: 8px;
    }
    .pdk-dns-optimizer__recommendation-metric {
      padding: 2px 6px;
      border-radius: 999px;
      background: rgba(127, 127, 127, 0.13);
      font-size: 11px;
    }
    .pdk-dns-optimizer__recommendation-actions {
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .pdk-dns-optimizer__recommendation-actions .cbi-button {
      min-height: 34px;
      padding-left: 16px;
      padding-right: 16px;
      font-weight: 700;
    }
    .pdk-dns-optimizer__pair {
      margin-top: 4px;
    }
    .pdk-dns-optimizer__pair > span {
      overflow-wrap: anywhere;
    }
    .pdk-dns-optimizer__table-wrap {
      width: 100%;
      overflow-x: auto;
      margin-top: 10px;
    }
    .pdk-dns-optimizer__table {
      width: 100%;
      min-width: 720px;
      border-collapse: collapse;
      table-layout: auto;
    }
    .pdk-dns-optimizer__table--main {
      min-width: 860px;
    }
    .pdk-dns-optimizer__table th,
    .pdk-dns-optimizer__table td {
      padding: 7px 8px;
      border-bottom: 1px solid rgba(127, 127, 127, 0.18);
      text-align: left;
      vertical-align: top;
      overflow-wrap: break-word;
      word-break: normal;
    }
    .pdk-dns-optimizer__table th {
      white-space: nowrap !important;
      overflow-wrap: normal !important;
      word-break: normal !important;
      hyphens: none;
    }
    .pdk-dns-optimizer__table--main th:nth-child(1) { width: 25%; }
    .pdk-dns-optimizer__table--main th:nth-child(2) { width: 12%; }
    .pdk-dns-optimizer__table--main th:nth-child(3) { width: 15%; }
    .pdk-dns-optimizer__table--main th:nth-child(4) { width: 25%; }
    .pdk-dns-optimizer__table--main th:nth-child(5) { width: 23%; }
    .pdk-dns-optimizer__metric-line + .pdk-dns-optimizer__metric-line {
      margin-top: 2px;
    }
    .pdk-dns-optimizer__checks {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      margin-top: 5px;
    }
    .pdk-dns-optimizer__check {
      display: inline-flex;
      align-items: center;
      max-width: 100%;
      padding: 2px 6px;
      border: 1px solid rgba(127, 127, 127, 0.3);
      border-radius: 999px;
      font-size: 11px;
      line-height: 1.35;
    }
    .pdk-dns-optimizer__check--ok {
      color: #2ebd85;
      border-color: rgba(46, 189, 133, 0.55);
      background: rgba(46, 189, 133, 0.08);
    }
    .pdk-dns-optimizer__check--warn {
      color: #e6a23c;
      border-color: rgba(230, 162, 60, 0.55);
      background: rgba(230, 162, 60, 0.08);
    }
    .pdk-dns-optimizer__check--bad {
      color: #ef5b6a;
      border-color: rgba(239, 91, 106, 0.55);
      background: rgba(239, 91, 106, 0.08);
    }
    .pdk-dns-optimizer__check--muted {
      color: var(--text-color-secondary, #a8b3c7);
    }
    .pdk-dns-optimizer__row--recommended {
      background: rgba(46, 189, 133, 0.08);
    }
    .pdk-dns-optimizer__badge {
      display: inline-block;
      margin: 4px 6px 0 0;
      padding: 1px 5px;
      border: 1px solid rgba(127, 127, 127, 0.35);
      border-radius: 4px;
      font-size: 11px;
    }
    .pdk-dns-optimizer__badge--current {
      color: #79adf8;
      border-color: rgba(95, 157, 247, 0.6);
    }
    .pdk-dns-optimizer__badge--comparison {
      color: #e6a23c;
      border-color: rgba(230, 162, 60, 0.55);
    }
    .pdk-dns-optimizer__badge--recommended {
      color: #2ebd85;
      border-color: rgba(46, 189, 133, 0.65);
    }
    .pdk-dns-optimizer__badge--secondary {
      color: #79adf8;
      border-color: rgba(95, 157, 247, 0.6);
    }
    .pdk-dns-optimizer__endpoint + .pdk-dns-optimizer__endpoint {
      margin-top: 6px;
      padding-top: 6px;
      border-top: 1px dashed rgba(127, 127, 127, 0.22);
    }
    .pdk-dns-optimizer__row-action {
      margin-top: 7px;
      max-width: 100%;
      white-space: normal;
    }
    .pdk-dns-optimizer__history {
      margin-top: 10px;
      border: 1px solid rgba(127, 127, 127, 0.22);
      border-radius: 6px;
      padding: 0 10px 10px;
    }
    .pdk-dns-optimizer__history > summary {
      padding: 9px 0;
      font-weight: 700;
    }
    .pdk-dns-optimizer__ok { color: #2ebd85; }
    .pdk-dns-optimizer__warn { color: #e6a23c; }
    .pdk-dns-optimizer__bad { color: #ef5b6a; }
    .pdk-dns-optimizer details { margin-top: 10px; }
    .pdk-dns-optimizer summary { cursor: pointer; }
    .pdk-dns-action-running .cbi-page-actions button {
      pointer-events: none;
      opacity: 0.55;
    }
    /* DNS optimizer MultiValue intrinsic containment */
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-value-field,
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-value-field,
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-value-field {
      min-width: 0;
      max-width: 100%;
    }
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-dropdown[multiple],
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-dropdown[multiple],
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-dropdown[multiple] {
      box-sizing: border-box;
      width: 100%;
      max-width: 100%;
      min-width: 0;
    }
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-dropdown[multiple] > ul:not(.dropdown),
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-dropdown[multiple] > ul:not(.dropdown),
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-dropdown[multiple] > ul:not(.dropdown) {
      min-width: 0;
      max-width: 100%;
      flex-wrap: wrap;
    }
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-dropdown[multiple] > ul:not(.dropdown) > li[display],
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-dropdown[multiple] > ul:not(.dropdown) > li[display],
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-dropdown[multiple] > ul:not(.dropdown) > li[display] {
      min-width: 0;
      max-width: 100%;
      flex: 0 1 auto;
    }
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-dropdown[multiple] > ul > li > form,
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-dropdown[multiple] > ul > li > form,
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-dropdown[multiple] > ul > li > form {
      display: none;
    }
    #view .cbi-value[data-name="dns_optimizer_protocols"] .cbi-dropdown[multiple][open] > ul.dropdown > li > form,
    #view .cbi-value[data-name="dns_optimizer_candidates"] .cbi-dropdown[multiple][open] > ul.dropdown > li > form,
    #view .cbi-value[data-name="dns_optimizer_bootstrap_candidates"] .cbi-dropdown[multiple][open] > ul.dropdown > li > form {
      display: inline-block;
    }
    /* DNS optimizer MultiValue intrinsic containment end */
    /* Native LuCI dropdowns keep their keyboard, validation and value handling. */
    #view .pdk-settings-multivalue {
      box-sizing: border-box;
      /* Defeat the older containment rule and theme intrinsic sizing. */
      width: min(100%, 30rem) !important;
      max-width: min(100%, 30rem) !important;
      min-width: 0 !important;
    }
    #view .pdk-settings-multivalue > ul:not(.dropdown),
    #view .pdk-settings-multivalue > .more {
      display: none !important;
    }
    #view .pdk-settings-multivalue > .pdk-settings-multivalue__summary {
      display: block;
      padding: 0.3rem 1.5rem 0.3rem 0.5rem;
      min-width: 0;
      max-width: 100%;
      white-space: normal;
      overflow-wrap: anywhere;
    }
    #view .pdk-settings-multivalue > ul > li,
    #view .pdk-settings-multivalue > ul > li > label {
      min-width: 0;
      max-width: 100%;
      white-space: normal;
      overflow-wrap: anywhere;
    }
    #view .pdk-settings-multivalue:not([open]) > ul > li > form,
    #view .pdk-settings-multivalue[open] > ul.preview > li > form {
      display: none;
    }
    #view .pdk-settings-multivalue[open] > ul.dropdown {
      box-sizing: border-box;
      width: 100%;
      max-width: 100%;
      min-width: 0;
      left: 0 !important;
      right: 0 !important;
    }
    @media (max-width: 800px) {
      .pdk-dns-optimizer { padding: 10px; }
      .pdk-dns-optimizer__actions { width: 100%; }
      .pdk-dns-optimizer__actions button {
        flex: 1 1 100%;
        min-height: 44px;
      }
      .pdk-dns-optimizer__recommendation-grid {
        grid-template-columns: minmax(0, 1fr);
      }
      .pdk-dns-optimizer__recommendation-actions,
      .pdk-dns-optimizer__recommendation-actions .cbi-button {
        width: 100%;
        min-height: 44px;
      }
      .pdk-dns-optimizer__table-wrap {
        overflow-x: visible;
      }
      .pdk-dns-optimizer__table--main,
      .pdk-dns-optimizer__table--bootstrap {
        display: block;
        width: 100%;
        min-width: 0;
      }
      .pdk-dns-optimizer__table--main thead,
      .pdk-dns-optimizer__table--bootstrap thead {
        display: none;
      }
      .pdk-dns-optimizer__table--main tbody,
      .pdk-dns-optimizer__table--main tr,
      .pdk-dns-optimizer__table--main td,
      .pdk-dns-optimizer__table--bootstrap tbody,
      .pdk-dns-optimizer__table--bootstrap tr,
      .pdk-dns-optimizer__table--bootstrap td {
        display: block;
        width: auto;
      }
      .pdk-dns-optimizer__table--main tr,
      .pdk-dns-optimizer__table--bootstrap tr {
        box-sizing: border-box;
        padding: 8px;
        margin-bottom: 10px;
        border: 1px solid rgba(127, 127, 127, 0.22);
        border-radius: 6px;
      }
      .pdk-dns-optimizer__table--main td,
      .pdk-dns-optimizer__table--bootstrap td {
        display: grid;
        grid-template-columns: minmax(92px, 34%) minmax(0, 1fr);
        gap: 8px;
        padding: 6px 2px;
        overflow-wrap: anywhere;
      }
      .pdk-dns-optimizer__table--main td::before,
      .pdk-dns-optimizer__table--bootstrap td::before {
        content: attr(data-label);
        color: var(--text-color-secondary, #a8b3c7);
        font-size: 11px;
        font-weight: 700;
        text-transform: uppercase;
      }
    }
  `;
  document.head.appendChild(style);
}

function protocolLabel(protocol) {
  return (
    { auto: "Авто", udp: "UDP", tcp: "TCP", doh: "DoH", dot: "DoT", doq: "DoQ", h3: "H3" }[protocol] || protocol
  );
}

function normalizeProtocolSelection(value) {
  const values = Array.isArray(value)
    ? value
    : String(value || "")
        .split(/[\s,]+/)
        .filter(Boolean);
  const selected = new Set(values);
  if (selected.has("auto")) {
    return ["udp", "doh", "dot"];
  }
  return ["udp", "tcp", "doh", "dot"].filter((protocol) => selected.has(protocol));
}

function benchmarkProtocolLabel(status) {
  const protocols = normalizeProtocolSelection(
    status?.protocols || status?.protocol,
  );
  return protocols.length
    ? protocols.map(protocolLabel).join(" · ")
    : protocolLabel(status?.protocol || "auto");
}

function profileLabel(profile) {
  return (
    {
      unfiltered: "Без фильтрации",
      security: "Защита от вредоносных доменов",
      security_ecs: "Защита + ECS для CDN",
      privacy: "Упор на приватность",
      isp: "DNS провайдера",
      custom: "Пользовательский DNS",
    }[profile] || ""
  );
}

function optimizerMessage(status) {
  const messages = {
    idle: "Нажмите «Подобрать DNS». Проверка ничего не меняет в настройках.",
    starting: "Запускаем проверку DNS…",
    benchmarking_bootstrap: "Проверяем bootstrap DNS…",
    benchmarking_main: "Проверяем основные DNS-серверы…",
    benchmarking_main_udp: "Проверяем DNS по UDP…",
    benchmarking_main_doh: "Проверяем DNS по DoH…",
    benchmarking_main_dot: "Проверяем DNS по DoT…",
    benchmark_complete:
      "Подбор завершён. Лучший доступный комплект уже выбран.",
    no_reliable_dns:
      "Ни одна пара не прошла все проверки. Настройки не изменены.",
    no_universal_pair:
      "Ни одна известная публичная нефильтрующая пара не прошла все проверки. DNS провайдера и пользовательские адреса показаны только для сравнения.",
    saving_previous_dns:
      "Сохраняем предыдущие DNS-настройки для быстрого отката…",
    restarting_podkop: "Устанавливаем DNS и перезапускаем Podkop…",
    validating_dns: "Проверяем sing-box, DNS, FakeIP и dnsmasq…",
    rolling_back: "Проверка не пройдена. Автоматически возвращаем прежние DNS…",
    apply_complete:
      "DNS установлен и полностью проверен. Поля обновлены без перезагрузки страницы.",
    apply_failed_rolled_back:
      "Новая пара не прошла проверку. Прежние DNS автоматически восстановлены.",
    apply_failed_rollback_failed:
      "Не удалось применить DNS и автоматический откат завершился ошибкой.",
    bootstrap_incompatible:
      "Выбранный bootstrap DNS не разрешает адрес основного DNS.",
    invalid_recommendation:
      "Результат подбора устарел. Запустите проверку ещё раз.",
    stale_candidate:
      "Адрес этой строки изменился после проверки. Для безопасности запустите проверку ещё раз.",
    primary_dns_not_allowed:
      "Yandex DNS можно использовать только как bootstrap DNS.",
    secondary_dns_not_allowed:
      "Yandex DNS нельзя установить как резервный upstream. Он доступен только для bootstrap.",
    secondary_arguments_required:
      "Резервная DNS-пара задана не полностью. Применение отменено.",
    invalid_secondary_recommendation:
      "Результат резервной пары устарел. Запустите проверку ещё раз.",
    stale_secondary_candidate:
      "Адрес резервной пары изменился после проверки. Запустите проверку ещё раз.",
    secondary_bootstrap_incompatible:
      "Bootstrap резервной пары не разрешает адрес её DoH/DoT-сервера.",
    failover_switch_in_progress:
      "Сейчас завершается автоматическое переключение DNS. Повторите действие через несколько секунд.",
    backup_failed: "Не удалось сохранить прежние DNS. Применение отменено.",
    no_previous_dns: "Нет сохранённых DNS для отката.",
    rollback_complete:
      "Предыдущие DNS восстановлены и проверены. Поля обновлены без перезагрузки страницы.",
    rollback_failed: "Не удалось восстановить предыдущие DNS.",
    worker_start_failed: "Не удалось запустить фоновую проверку DNS.",
    worker_stopped: "Фоновая проверка неожиданно остановилась.",
  };

  return messages[status?.message] || "Готово.";
}

async function callDnsOptimizer(args) {
  const response = await fs.exec(DNS_OPTIMIZER_COMMAND, args);
  const stdout = (response?.stdout || "").trim();
  if (!stdout) {
    throw new Error(
      (response?.stderr || "Команда не вернула результат").trim(),
    );
  }

  try {
    return JSON.parse(stdout);
  } catch (_error) {
    throw new Error(stdout);
  }
}

function renderActionButton(text, className, disabled, onClick) {
  return E(
    "button",
    {
      type: "button",
      class: `cbi-button ${className}`,
      disabled: disabled || undefined,
      click: onClick,
    },
    text,
  );
}

function isUniversalProfile(profile) {
  return profile === "unfiltered" || profile === "privacy";
}

function dnsEndpointHost(value) {
  const withoutScheme = String(value || "")
    .trim()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
  const authority = withoutScheme.split("/")[0];
  if (authority.startsWith("[")) {
    return authority.slice(1, authority.indexOf("]")).toLowerCase();
  }
  return authority.replace(/:\d+$/, "").toLowerCase();
}

function candidateIsPrimaryEligible(candidate) {
  if (!candidate) {
    return false;
  }

  const endpoint = dnsEndpointHost(candidate.dnsServer);
  const candidateId = String(candidate.id || "").toLowerCase();
  const provider = String(candidate.provider || "").toLowerCase();
  const policy =
    DNS_PRIMARY_POLICY[candidateId] ||
    (candidateId === "yandex" ||
    candidateId.startsWith("yandex_") ||
    provider === "yandex" ||
    provider.startsWith("yandex ")
      ? DNS_PRIMARY_POLICY.yandex
      : null) ||
    (/^77\.88\.8\.\d+$/.test(endpoint) ||
    endpoint.endsWith(".dns.yandex.net") ||
    endpoint === "dns.yandex.net" ||
    endpoint.endsWith(".dns.yandex.ru") ||
    endpoint === "dns.yandex.ru"
      ? DNS_PRIMARY_POLICY.yandex
      : null);
  if (policy?.primaryEligible === false) {
    return false;
  }
  return candidate.primaryEligible !== false;
}

function isComparisonOnly(result) {
  return (
    !candidateIsPrimaryEligible(result) ||
    !isUniversalProfile(result?.profile) ||
    result?.bootstrapUniversalEligible !== true
  );
}

function benchmarkSnapshot(status) {
  if (Array.isArray(status?.results) && status.results.length) {
    return status;
  }
  if (
    Array.isArray(status?.lastBenchmark?.results) &&
    status.lastBenchmark.results.length
  ) {
    return status.lastBenchmark;
  }
  return null;
}

function currentDnsPair() {
  return {
    protocol: uci.get("podkop", "settings", "dns_type") || "udp",
    dnsServer: uci.get("podkop", "settings", "dns_server") || "",
    bootstrapDnsServer:
      uci.get("podkop", "settings", "bootstrap_dns_server") || "",
  };
}

function isCurrentPair(result) {
  const current = currentDnsPair();
  return (
    current.protocol === result?.protocol &&
    current.dnsServer === result?.dnsServer &&
    current.bootstrapDnsServer === result?.bootstrapDnsServer
  );
}

function formatBenchmarkTime(value) {
  if (!value) {
    return "";
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }
  return parsed.toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function resultClass(result) {
  const communityResults = Array.isArray(result.communityResults)
    ? result.communityResults
    : [];
  if (
    communityResults.some(
      (item) => item.tested === true && item.passed !== true,
    )
  ) {
    return "pdk-dns-optimizer__bad";
  }
  if (
    Number(result.compatibilityPassed || 0) <
      Number(result.compatibilityTotal || 0) ||
    (Number.isFinite(result.compatibilityScore) &&
      result.compatibilityScore < 90)
  ) {
    return "pdk-dns-optimizer__bad";
  }
  if (result.reliable) {
    const tailSpread = Math.max(0, (result.p90Ms || 0) - result.medianMs);
    return result.jitterMs <= 15 && tailSpread <= 25
      ? "pdk-dns-optimizer__ok"
      : "pdk-dns-optimizer__warn";
  }
  return "pdk-dns-optimizer__bad";
}

function resultVerdict(result) {
  const tailSpread = Math.max(0, (result.p90Ms || 0) - result.medianMs);
  const communityResults = Array.isArray(result.communityResults)
    ? result.communityResults
    : [];
  if (result.reliable && !candidateIsPrimaryEligible(result)) {
    return "Стабильно, доступно только как резервный DNS";
  }
  if (
    Number(result.compatibilityPassed || 0) <
      Number(result.compatibilityTotal || 0) ||
    (Number.isFinite(result.compatibilityScore) &&
      result.compatibilityScore < 90)
  ) {
    return "Сбои на проверочных сервисах";
  }
  if (
    communityResults.some(
      (item) => item.tested === true && item.passed !== true,
    )
  ) {
    return "Недоступен выбранный сервис";
  }
  if (
    result.reliable &&
    (result.profile === "isp" || result.profile === "custom")
  ) {
    return "Стабильно в этом тесте, только для сравнения";
  }
  if (result.reliable && result.universalEligible === false) {
    return "Стабильно, но DNS с фильтрацией";
  }
  if (result.reliable && result.jitterMs <= 15 && tailSpread <= 25) {
    return "Отлично";
  }
  if (result.reliable) {
    return "Стабильно, но задержка плавает";
  }
  if (result.error === "bootstrap_failed") {
    return "Нет совместимого bootstrap";
  }
  if (result.error === "nxdomain_check_failed") {
    return "Возможна подмена DNS-ответов";
  }
  if (result.error === "community_service_failed") {
    return "Проблема с выбранным списком";
  }
  return "Есть потери или тайм-ауты";
}

function compatibilityLabel(result) {
  const passed = Number(result.compatibilityPassed || 0);
  const total = Number(result.compatibilityTotal || 0);
  if (!total) {
    return "—";
  }
  return `${passed}/${total}`;
}

function compatibilityTitle(result) {
  const failures = Array.isArray(result.compatibilityFailures)
    ? result.compatibilityFailures
    : [];
  const unstable = Array.isArray(result.compatibilityUnstable)
    ? result.compatibilityUnstable
    : [];
  if (!failures.length && !unstable.length) {
    return "Все проверочные сервисы стабильно разрешаются";
  }
  const details = [];
  if (failures.length) {
    details.push(`не разрешаются: ${failures.join(", ")}`);
  }
  if (unstable.length) {
    details.push(`один из двух запросов не прошёл: ${unstable.join(", ")}`);
  }
  return details.join("; ");
}

const COMMUNITY_SERVICE_LABELS = {
  russia_inside: "Россия внутри",
  russia_outside: "Россия снаружи",
  ukraine_inside: "Украина",
  geoblock: "Геоблокировка",
  block: "Блокировки",
  porn: "Контент 18+",
  news: "Новости",
  anime: "Аниме",
  youtube: "YouTube",
  hdrezka: "HDRezka",
  tiktok: "TikTok",
  google_ai: "Google AI",
  google_play: "Google Play",
  hodca: "H.O.D.C.A",
  discord: "Discord",
  meta: "Meta",
  twitter: "Twitter (X)",
  telegram: "Telegram",
  roblox: "Roblox",
  cloudflare: "Cloudflare ASN",
  cloudfront: "CloudFront ASN",
  digitalocean: "DigitalOcean ASN",
  hetzner: "Hetzner ASN",
  ovh: "OVH ASN",
};

function communityServiceLabel(id) {
  const label =
    COMMUNITY_SERVICE_LABELS[id] ||
    main.DOMAIN_LIST_OPTIONS?.[id] ||
    id ||
    "Список";
  return typeof _ === "function" ? _(label) : label;
}

function communityResultTitle(item) {
  if (item.tested !== true) {
    return "Для этого списка нет отдельной DNS-проверки; он не влияет на рекомендацию";
  }
  const details = [];
  if (Array.isArray(item.failures) && item.failures.length) {
    details.push(`не разрешаются: ${item.failures.join(", ")}`);
  }
  if (Array.isArray(item.unstable) && item.unstable.length) {
    details.push(
      `один из двух запросов не прошёл: ${item.unstable.join(", ")}`,
    );
  }
  return details.length
    ? details.join("; ")
    : `${item.stableDomains || 0}/${item.totalDomains || 0} доменов стабильны в обоих проходах`;
}

function renderCommunityCheck(item) {
  const label = communityServiceLabel(item.id);
  let stateClass = "pdk-dns-optimizer__check--muted";
  let suffix = "не проверяется по DNS";
  if (item.tested === true && item.passed !== true) {
    stateClass = "pdk-dns-optimizer__check--bad";
    suffix = `${item.passedDomains || 0}/${item.totalDomains || 0}`;
  } else if (item.tested === true && item.stable !== true) {
    stateClass = "pdk-dns-optimizer__check--warn";
    suffix = `${item.passedDomains || 0}/${item.totalDomains || 0}, нестабильно`;
  } else if (item.tested === true) {
    stateClass = "pdk-dns-optimizer__check--ok";
    suffix = `${item.passedDomains || 0}/${item.totalDomains || 0}`;
  }

  return E(
    "span",
    {
      class: `pdk-dns-optimizer__check ${stateClass}`,
      title: communityResultTitle(item),
    },
    `${label}: ${suffix}`,
  );
}

function renderChecks(result) {
  const communityResults = Array.isArray(result.communityResults)
    ? result.communityResults
    : [];
  const baseClass =
    Number(result.compatibilityPassed || 0) ===
    Number(result.compatibilityTotal || 0)
      ? "pdk-dns-optimizer__check--ok"
      : "pdk-dns-optimizer__check--bad";
  const checks = [
    E(
      "span",
      {
        class: `pdk-dns-optimizer__check ${baseClass}`,
        title: compatibilityTitle(result),
      },
      `База: ${compatibilityLabel(result)}`,
    ),
    ...communityResults.map(renderCommunityCheck),
  ];

  return E("div", { class: "pdk-dns-optimizer__checks" }, checks);
}

function communityRecommendationText(result) {
  const selected = Number(result.communitySelected || 0);
  const tested = Number(result.communityTested || 0);
  const passed = Number(result.communityPassed || 0);
  if (!selected) {
    return "Списки сообщества не выбраны.";
  }
  const untested = Math.max(0, selected - tested);
  const untestedText = untested
    ? ` Ещё ${untested} выбрано, но не имеет отдельной DNS-проверки.`
    : "";
  return `Выбранные списки: ${passed}/${tested} проверенных доступны.${untestedText}`;
}

function recommendationExplanation(status) {
  const confidence = Number.isFinite(status.recommendationConfidence)
    ? status.recommendationConfidence
    : 100;
  if (status.recommendationReason === "close_results_keep_current") {
    return "Статистического преимущества нет: варианты практически равны, поэтому сохранён текущий DNS без случайного переключения.";
  }
  if (status.recommendationReason === "close_results") {
    return `Преимущество слабое (${confidence}%): выбран лучший вариант по полной выборке.`;
  }
  return `Уверенность в преимуществе: ${confidence}%.`;
}

function recommendationSetConfigured(primary, secondary) {
  if (!primary || !secondary) {
    return false;
  }
  return (
    String(uci.get("podkop", "settings", "dns_type") || "") ===
      String(primary.protocol || "") &&
    String(uci.get("podkop", "settings", "dns_server") || "") ===
      String(primary.dnsServer || "") &&
    String(uci.get("podkop", "settings", "bootstrap_dns_server") || "") ===
      String(primary.bootstrapDnsServer || "") &&
    String(uci.get("podkop", "settings", "dns_failover_enabled") || "0") ===
      "1" &&
    String(uci.get("podkop", "settings", "secondary_dns_type") || "") ===
      String(secondary.protocol || "") &&
    String(uci.get("podkop", "settings", "secondary_dns_server") || "") ===
      String(secondary.dnsServer || "") &&
    String(
      uci.get("podkop", "settings", "secondary_bootstrap_dns_server") || "",
    ) === String(secondary.bootstrapDnsServer || "")
  );
}

function recommendationSetInstalled(primary, secondary) {
  return (
    recommendationSetConfigured(primary, secondary) &&
    String(
      uci.get("podkop", "settings", "dns_failover_active_slot") || "primary",
    ) !== "secondary"
  );
}

function renderRecommendationPair(result, primary) {
  const testedServices = Number(result.communityTested || 0);
  const passedServices = Number(result.communityPassed || 0);
  const serviceMetric = testedServices
    ? `Сервисы ${passedServices}/${testedServices}`
    : `База ${compatibilityLabel(result)}`;

  return E(
    "div",
    {
      class: `pdk-dns-optimizer__recommendation-card${
        primary ? " pdk-dns-optimizer__recommendation-card--primary" : ""
      }`,
    },
    [
      E(
        "div",
        { class: "pdk-dns-optimizer__recommendation-role" },
        primary
          ? "1 · Основная — используется первой"
          : "2 · Резервная — включится после двух отказов",
      ),
      E("div", { class: "pdk-dns-optimizer__recommendation-endpoint" }, [
        `${result.provider} · ${result.dnsServer}`,
        E(
          "span",
          { class: "pdk-dns-optimizer__badge" },
          protocolLabel(result.protocol),
        ),
      ]),
      E(
        "div",
        { class: "pdk-dns-optimizer__recommendation-bootstrap" },
        `Bootstrap: ${result.bootstrapProvider || "DNS"} · ${result.bootstrapDnsServer}`,
      ),
      E("div", { class: "pdk-dns-optimizer__recommendation-metrics" }, [
        E(
          "span",
          { class: "pdk-dns-optimizer__recommendation-metric" },
          `Надёжность ${result.successRate}%`,
        ),
        E(
          "span",
          { class: "pdk-dns-optimizer__recommendation-metric" },
          serviceMetric,
        ),
        E(
          "span",
          { class: "pdk-dns-optimizer__recommendation-metric" },
          `P90 ${result.p90Ms} мс`,
        ),
      ]),
    ],
  );
}

function renderRecommendation(status, running) {
  const result = status?.recommendation;
  if (
    !result ||
    !candidateIsPrimaryEligible(result) ||
    result.universalEligible !== true ||
    result.bootstrapUniversalEligible !== true
  ) {
    return E("div");
  }

  const secondary = pickSecondaryFor(status, result);
  const configured = recommendationSetConfigured(result, secondary);
  const installed = recommendationSetInstalled(result, secondary);
  const reserveActive = configured && !installed;
  const canInstall = Boolean(secondary);

  return E("div", { class: "pdk-dns-optimizer__recommendation" }, [
    E("div", { class: "pdk-dns-optimizer__recommendation-header" }, [
      E("div", {}, [
        E(
          "div",
          { class: "pdk-dns-optimizer__recommendation-title" },
          "Лучший безопасный комплект найден",
        ),
        E(
          "div",
          { class: "pdk-dns-optimizer__detail" },
          "Подбор уже сделал выбор — сравнивать строки таблицы вручную не нужно.",
        ),
      ]),
      E(
        "span",
        {
          class:
            "pdk-dns-optimizer__badge pdk-dns-optimizer__badge--recommended",
        },
        "Рекомендуется",
      ),
    ]),
    E("div", { class: "pdk-dns-optimizer__recommendation-grid" }, [
      renderRecommendationPair(result, true),
      ...(secondary
        ? [renderRecommendationPair(secondary, false)]
        : [
            E(
              "div",
              {
                class:
                  "pdk-dns-optimizer__recommendation-card pdk-dns-optimizer__warn",
              },
              "Независимая резервная связка не найдена. Измените набор проверяемых DNS и повторите подбор.",
            ),
          ]),
    ]),
    E(
      "div",
      { class: "pdk-dns-optimizer__detail" },
      canInstall
        ? `Podkop начнёт с основной связки и автоматически перейдёт на резервную после двух подтверждённых отказов. Возврат на первую связку выполняется вручную. ${communityRecommendationText(result)} ${recommendationExplanation(status)}`
        : "Без независимой резервной связки автоматическая установка отключена.",
    ),
    E("div", { class: "pdk-dns-optimizer__recommendation-actions" }, [
      renderActionButton(
        installed
          ? "Рекомендуемый комплект уже установлен"
          : reserveActive
            ? "Вернуть основную связку"
            : "Установить этот комплект",
        "cbi-button-apply",
        running || !canInstall || installed,
        () => applyDnsResult(result, secondary),
      ),
      E(
        "span",
        { class: "pdk-dns-optimizer__detail" },
        installed
          ? "Обе связки уже совпадают с настройками Podkop."
          : reserveActive
            ? "Комплект уже установлен, но сейчас активна резервная связка. Кнопка повторно проверит и включит основную."
            : canInstall
              ? "Обе связки сохранятся и будут проверены автоматически. При ошибке сработает откат."
              : "Добавьте больше независимых DNS-кандидатов и повторите тест.",
      ),
    ]),
  ]);
}

function renderMainResults(status, running) {
  const results = Array.isArray(status?.results)
    ? status.results.filter(candidateIsPrimaryEligible)
    : [];
  if (!results.length) {
    return E("div");
  }

  const recommendedSecondary = status?.recommendation
    ? pickSecondaryFor(status, status.recommendation)
    : null;
  const rows = results.map((result) => {
    const classes = [];
    const currentPrimary = isCurrentPair(result);
    const comparisonOnly = isComparisonOnly(result);
    const rowSecondary = pickSecondaryFor(status, result);
    const rowConfigured = recommendationSetConfigured(result, rowSecondary);
    const rowSetInstalled = recommendationSetInstalled(result, rowSecondary);
    const recommended =
      candidateIsPrimaryEligible(result) &&
      status.recommendation?.protocol === result.protocol &&
      status.recommendation?.id === result.id &&
      status.recommendation?.dnsServer === result.dnsServer &&
      status.recommendation?.bootstrapDnsServer === result.bootstrapDnsServer;
    const secondaryRecommended =
      recommendedSecondary?.protocol === result.protocol &&
      recommendedSecondary?.id === result.id &&
      recommendedSecondary?.dnsServer === result.dnsServer &&
      recommendedSecondary?.bootstrapDnsServer === result.bootstrapDnsServer;
    if (recommended) {
      classes.push("pdk-dns-optimizer__row--recommended");
    }
    if (currentPrimary) {
      classes.push("pdk-dns-optimizer__row--current");
    }

    return E("tr", { class: classes.join(" ") }, [
      E("td", { "data-label": "Пара DNS" }, [
        E("div", { class: "pdk-dns-optimizer__endpoint" }, [
          E("b", {}, result.provider),
          E("div", { class: "pdk-dns-optimizer__detail" }, result.dnsServer),
        ]),
        E("div", { class: "pdk-dns-optimizer__endpoint" }, [
          E("b", {}, `Bootstrap: ${result.bootstrapProvider || "—"}`),
          E(
            "div",
            { class: "pdk-dns-optimizer__detail" },
            result.bootstrapDnsServer || "—",
          ),
        ]),
        E(
          "span",
          { class: "pdk-dns-optimizer__badge" },
          protocolLabel(result.protocol),
        ),
        ...(recommended
          ? [
              E(
                "span",
                {
                  class:
                    "pdk-dns-optimizer__badge pdk-dns-optimizer__badge--recommended",
                },
                "Лучший",
              ),
            ]
          : []),
        ...(secondaryRecommended
          ? [
              E(
                "span",
                {
                  class:
                    "pdk-dns-optimizer__badge pdk-dns-optimizer__badge--secondary",
                },
                "Резервный",
              ),
            ]
          : []),
        ...(currentPrimary
          ? [
              E(
                "span",
                {
                  class:
                    "pdk-dns-optimizer__badge pdk-dns-optimizer__badge--current",
                },
                "Настроена как основная",
              ),
            ]
          : []),
        ...(comparisonOnly
          ? [
              E(
                "span",
                {
                  class:
                    "pdk-dns-optimizer__badge pdk-dns-optimizer__badge--comparison",
                },
                candidateIsPrimaryEligible(result)
                  ? "Только для сравнения"
                  : "Только для резерва",
              ),
            ]
          : []),
      ]),
      E("td", { "data-label": "Надёжность", class: resultClass(result) }, [
        E("b", {}, `Основной: ${result.successRate}%`),
        E(
          "div",
          { class: "pdk-dns-optimizer__detail" },
          `${result.successCount}/${result.totalQueries}`,
        ),
        E(
          "div",
          { class: "pdk-dns-optimizer__detail" },
          Number.isFinite(result.bootstrapSuccessRate)
            ? `Bootstrap: ${result.bootstrapSuccessRate}%`
            : "Bootstrap: —",
        ),
      ]),
      E("td", { "data-label": "Задержка" }, [
        E(
          "div",
          { class: "pdk-dns-optimizer__metric-line" },
          `Медиана: ${Number.isFinite(result.medianMs) ? `${result.medianMs} мс` : "—"}`,
        ),
        E(
          "div",
          { class: "pdk-dns-optimizer__metric-line" },
          `P90: ${Number.isFinite(result.p90Ms) ? `${result.p90Ms} мс` : "—"}`,
        ),
        E(
          "div",
          { class: "pdk-dns-optimizer__metric-line" },
          `IQR: ${result.jitterMs || result.reliable ? `${result.jitterMs} мс` : "—"}`,
        ),
        E(
          "div",
          { class: "pdk-dns-optimizer__detail" },
          Number.isFinite(result.bootstrapP90Ms)
            ? `Bootstrap P90: ${result.bootstrapP90Ms} мс`
            : `Bootstrap: ${result.bootstrapMedianMs || 0} мс`,
        ),
      ]),
      E("td", { "data-label": "Проверки" }, renderChecks(result)),
      E(
        "td",
        { "data-label": "Оценка и действие", class: resultClass(result) },
        [
          E("div", {}, resultVerdict(result)),
          E(
            "div",
            { class: "pdk-dns-optimizer__detail" },
            profileLabel(result.profile),
          ),
          E("div", { class: "pdk-dns-optimizer__row-action" }, [
            renderActionButton(
              rowSetInstalled
                ? "Установлена"
                : rowConfigured
                  ? "Вернуть основную"
                  : "Установить вручную",
              comparisonOnly ? "cbi-button-neutral" : "cbi-button-apply",
              running ||
                rowSetInstalled ||
                comparisonOnly ||
                result.reliable !== true ||
                !rowSecondary,
              () => applyDnsResult(result, rowSecondary),
            ),
            ...(!comparisonOnly && rowSecondary
              ? [
                  E(
                    "div",
                    { class: "pdk-dns-optimizer__detail" },
                    `Резерв: ${rowSecondary.provider} · ${rowSecondary.dnsServer} (${protocolLabel(rowSecondary.protocol)}); bootstrap ${rowSecondary.bootstrapProvider || "DNS"} · ${rowSecondary.bootstrapDnsServer}`,
                  ),
                ]
              : []),
          ]),
        ],
      ),
    ]);
  });

  return E("div", { class: "pdk-dns-optimizer__table-wrap" }, [
    E(
      "table",
      { class: "pdk-dns-optimizer__table pdk-dns-optimizer__table--main" },
      [
        E("thead", {}, [
          E("tr", {}, [
            E("th", {}, "Пара DNS"),
            E("th", {}, "Надёжность"),
            E("th", {}, "Задержка"),
            E("th", {}, "Проверки"),
            E("th", {}, "Оценка и действие"),
          ]),
        ]),
        E("tbody", {}, rows),
      ],
    ),
  ]);
}

function pickSecondaryFor(status, primary) {
  const candidates = [
    status?.recommendation,
    status?.secondaryRecommendation,
    ...(Array.isArray(status?.results) ? status.results : []),
  ];
  const eligible = candidates.filter(
    (candidate) =>
      candidate &&
      candidate.id !== primary?.id &&
      candidate.dnsServer !== primary?.dnsServer &&
      candidate.provider !== primary?.provider &&
      candidateIsPrimaryEligible(candidate) &&
      candidate.reliable === true &&
      candidate.universalEligible === true &&
      candidate.bootstrapUniversalEligible === true,
  );
  return (
    eligible.find(
      (candidate) =>
        candidate.bootstrapDnsServer !== primary?.bootstrapDnsServer,
    ) ||
    eligible[0] ||
    null
  );
}

function renderBenchmarkHistory(status, running) {
  if (!status) {
    return E("div");
  }
  const resultCount = Array.isArray(status.results) ? status.results.length : 0;
  const label = `${running ? "Предыдущие подробные результаты" : "Подробные результаты"} · ${resultCount} вариантов · ${benchmarkProtocolLabel(status)}${status.updatedAt ? ` · ${formatBenchmarkTime(status.updatedAt)}` : ""}`;
  return E(
    "details",
    {
      class: "pdk-dns-optimizer__history",
      open: dnsOptimizerState.historyOpen || undefined,
      toggle: (event) => {
        dnsOptimizerState.historyOpen = Boolean(event.currentTarget?.open);
      },
    },
    [
      E("summary", {}, label),
      renderMainResults(status, running),
      renderBootstrapResults(status),
    ],
  );
}

function renderBootstrapResults(status) {
  const results = Array.isArray(status.bootstrapResults)
    ? status.bootstrapResults
    : [];
  if (!results.length) {
    return E("div");
  }

  return E("details", {}, [
    E("summary", {}, `Результаты bootstrap DNS (${results.length})`),
    E("div", { class: "pdk-dns-optimizer__table-wrap" }, [
      E(
        "table",
        {
          class:
            "pdk-dns-optimizer__table pdk-dns-optimizer__table--bootstrap",
        },
        [
          E("thead", {}, [
            E("tr", {}, [
              E("th", {}, "Bootstrap DNS"),
              E("th", {}, "Адрес"),
              E("th", {}, "Успех"),
              E("th", {}, "Медиана"),
              E("th", {}, "P90"),
              E("th", {}, "Разброс IQR"),
              E("th", {}, "Тип"),
            ]),
          ]),
          E(
            "tbody",
            {},
            results.map((result) =>
              E("tr", {}, [
                E("td", { "data-label": "Bootstrap DNS" }, result.provider),
                E("td", { "data-label": "Адрес" }, result.server),
                E(
                  "td",
                  { "data-label": "Успех", class: resultClass(result) },
                  `${result.successRate}%`,
                ),
                E(
                  "td",
                  { "data-label": "Медиана" },
                  Number.isFinite(result.medianMs)
                    ? `${result.medianMs} мс`
                    : "—",
                ),
                E(
                  "td",
                  { "data-label": "P90" },
                  Number.isFinite(result.p90Ms) ? `${result.p90Ms} мс` : "—",
                ),
                E(
                  "td",
                  { "data-label": "Разброс IQR" },
                  result.jitterMs || result.reliable
                    ? `${result.jitterMs} мс`
                    : "—",
                ),
                E(
                  "td",
                  { "data-label": "Тип" },
                  profileLabel(result.profile),
                ),
              ]),
            ),
          ),
        ],
      ),
    ]),
  ]);
}

async function syncAppliedDnsToForm(status) {
  const operation = status?.operation || status?.action;
  const applied = status?.applied;
  if (
    status?.state !== "success" ||
    !["apply", "rollback"].includes(operation) ||
    !applied
  ) {
    return false;
  }

  const operationKey = `${operation}:${status.updatedAt || ""}`;
  if (dnsOptimizerState.syncedOperation === operationKey) {
    return false;
  }

  const fields = [
    {
      option: dnsOptimizerState.protocolOption,
      name: "dns_type",
      applied: applied.protocol,
    },
    {
      option: dnsOptimizerState.dnsServerOption,
      name: "dns_server",
      applied: applied.dnsServer,
    },
    {
      option: dnsOptimizerState.bootstrapDnsServerOption,
      name: "bootstrap_dns_server",
      applied: applied.bootstrapDnsServer,
    },
    {
      option: dnsOptimizerState.failoverEnabledOption,
      name: "dns_failover_enabled",
      applied: applied.failoverEnabled ? "1" : "0",
    },
    {
      option: dnsOptimizerState.secondaryProtocolOption,
      name: "secondary_dns_type",
      applied: applied.secondary?.protocol || "",
    },
    {
      option: dnsOptimizerState.secondaryDnsServerOption,
      name: "secondary_dns_server",
      applied: applied.secondary?.dnsServer || "",
    },
    {
      option: dnsOptimizerState.secondaryBootstrapDnsServerOption,
      name: "secondary_bootstrap_dns_server",
      applied: applied.secondary?.bootstrapDnsServer || "",
    },
  ];
  dnsOptimizerState.syncedOperation = operationKey;
  const before = fields.map((field) => ({
    ...field,
    formValue: field.option?.formvalue("settings"),
    cachedValue: uci.get("podkop", "settings", field.name),
  }));
  const hasManualChanges = before
    .filter((field) =>
      ["dns_type", "dns_server", "bootstrap_dns_server"].includes(field.name),
    )
    .some(
      (field) =>
        String(field.formValue ?? "") !== String(field.cachedValue ?? ""),
    );

  try {
    uci.unload("podkop");
    await uci.load("podkop");
    before.forEach((field) => {
      const value = hasManualChanges
        ? field.formValue
        : uci.get("podkop", "settings", field.name) || field.applied;
      if (!field.option || value == null || value === "") {
        return;
      }
      try {
        field.option.getUIElement("settings")?.setValue(value);
      } catch (_error) {
        // The status remains visible even if a third-party theme replaced a control.
      }
    });
    return true;
  } catch (_error) {
    dnsOptimizerState.syncedOperation = null;
    return false;
  }
}

function renderDnsOptimizer() {
  injectDnsOptimizerStyles();
  const status = dnsOptimizerState.status || {
    state: "idle",
    message: "idle",
    progress: 0,
  };
  const running = status.state === "running";
  const changing =
    running && (status.action === "apply" || status.action === "rollback");
  const benchmark = benchmarkSnapshot(status);
  const benchmarkRunning = running && status.action === "benchmark";

  if (changing) {
    document.body.classList.add("pdk-dns-action-running");
  } else {
    document.body.classList.remove("pdk-dns-action-running");
  }

  const node = E("div", { class: "pdk-dns-optimizer" }, [
    E("div", { class: "pdk-dns-optimizer__header" }, [
      E("div", {}, [
        E("div", { class: "pdk-dns-optimizer__title" }, "Автоподбор DNS"),
        E(
          "div",
          { class: "pdk-dns-optimizer__description" },
          "Сам проверяет стабильность, отсутствие подмены и выбранные сервисы Podkop, затем предлагает один готовый комплект из основной и резервной DNS-связок.",
        ),
      ]),
      E("div", { class: "pdk-dns-optimizer__actions" }, [
        renderActionButton(
          "Подобрать лучший DNS",
          "cbi-button-action",
          running,
          startDnsBenchmark,
        ),
        renderActionButton(
          "Откатить",
          "cbi-button-reset",
          running || !status.backupAvailable,
          rollbackDns,
        ),
      ]),
    ]),
    E("div", { class: "pdk-dns-optimizer__status" }, optimizerMessage(status)),
    E("div", { class: "pdk-dns-optimizer__progress" }, [
      E("span", {
        style: `width: ${Math.max(0, Math.min(100, status.progress || 0))}%`,
      }),
    ]),
    renderRecommendation(benchmark, running),
    renderBenchmarkHistory(benchmark, benchmarkRunning),
  ]);

  return node;
}

function updateDnsOptimizerNode() {
  if (!dnsOptimizerState.node?.parentNode) {
    return;
  }
  const replacement = renderDnsOptimizer();
  dnsOptimizerState.node.replaceWith(replacement);
  dnsOptimizerState.node = replacement;
}

function scheduleDnsOptimizerRefresh(delay) {
  if (dnsOptimizerState.pollTimer) {
    window.clearTimeout(dnsOptimizerState.pollTimer);
  }
  dnsOptimizerState.pollTimer = window.setTimeout(
    refreshDnsOptimizerStatus,
    delay,
  );
}

async function refreshDnsOptimizerStatus() {
  if (dnsOptimizerState.pollTimer) {
    window.clearTimeout(dnsOptimizerState.pollTimer);
    dnsOptimizerState.pollTimer = null;
  }

  try {
    dnsOptimizerState.status = await callDnsOptimizer(["status"]);
  } catch (error) {
    dnsOptimizerState.status = {
      state: "error",
      message: "worker_stopped",
      progress: 100,
      error: error.message,
    };
  }
  await syncAppliedDnsToForm(dnsOptimizerState.status);
  if (dnsOptimizerState.status.state !== "running") {
    dnsOptimizerState.applyingCandidateKey = null;
  }
  updateDnsOptimizerNode();

  if (dnsOptimizerState.status.state === "running") {
    dnsOptimizerState.pollTimer = window.setTimeout(
      refreshDnsOptimizerStatus,
      1000,
    );
  }
}

async function startDnsBenchmark() {
  const protocols = normalizeProtocolSelection(
    dnsOptimizerState.benchmarkProtocolsOption?.formvalue("settings") ||
      uci.get("podkop", "settings", "dns_optimizer_protocols") || [
        "udp",
        "doh",
        "dot",
      ],
  );
  const selectedProtocols = protocols.length
    ? protocols
    : ["udp", "doh", "dot"];
  const protocolArgument =
    selectedProtocols.length === 3 ? "auto" : selectedProtocols.join(",");
  dnsOptimizerState.status = {
    state: "running",
    action: "benchmark",
    message: "starting",
    protocol: selectedProtocols.length > 1 ? "auto" : selectedProtocols[0],
    protocols: selectedProtocols,
    progress: 0,
    lastBenchmark: benchmarkSnapshot(dnsOptimizerState.status),
  };
  dnsOptimizerState.historyOpen = false;
  updateDnsOptimizerNode();
  scheduleDnsOptimizerRefresh(250);

  try {
    const result = await callDnsOptimizer([
      "benchmark_start",
      protocolArgument,
    ]);
    if (!result.success) {
      if (result.error === "busy") {
        return;
      }
      throw new Error(result.error || "start_failed");
    }
    scheduleDnsOptimizerRefresh(250);
  } catch (_error) {
    scheduleDnsOptimizerRefresh(250);
  }
}

async function applyDnsResult(result, secondaryResult = null) {
  if (
    !result ||
    !candidateIsPrimaryEligible(result) ||
    (secondaryResult && !candidateIsPrimaryEligible(secondaryResult)) ||
    dnsOptimizerState.status?.state === "running"
  ) {
    return;
  }
  const candidateKey = `${result.protocol}:${result.id}:${result.dnsServer}:${result.bootstrapDnsServer}:${secondaryResult?.id || "single"}`;
  dnsOptimizerState.applyingCandidateKey = candidateKey;
  dnsOptimizerState.status = {
    state: "running",
    action: "apply",
    message: "saving_previous_dns",
    progress: 5,
    lastBenchmark: benchmarkSnapshot(dnsOptimizerState.status),
  };
  updateDnsOptimizerNode();
  scheduleDnsOptimizerRefresh(250);

  try {
    const args = [
      "apply_start",
      result.protocol,
      result.id,
      result.bootstrapDnsServer,
      result.dnsServer,
    ];
    if (secondaryResult) {
      args.push(
        secondaryResult.protocol,
        secondaryResult.id,
        secondaryResult.bootstrapDnsServer,
        secondaryResult.dnsServer,
      );
    }
    const response = await callDnsOptimizer(args);
    if (!response.success) {
      if (response.error === "busy") {
        return;
      }
      throw new Error(response.error || "start_failed");
    }
    scheduleDnsOptimizerRefresh(250);
  } catch (_error) {
    scheduleDnsOptimizerRefresh(250);
  }
}

async function rollbackDns() {
  const lastBenchmark = benchmarkSnapshot(dnsOptimizerState.status);
  dnsOptimizerState.status = {
    state: "running",
    action: "rollback",
    message: "rolling_back",
    progress: 5,
    lastBenchmark,
  };
  updateDnsOptimizerNode();
  scheduleDnsOptimizerRefresh(250);

  try {
    const result = await callDnsOptimizer(["rollback_start"]);
    if (!result.success) {
      if (result.error === "busy") {
        return;
      }
      throw new Error(result.error || "start_failed");
    }
    scheduleDnsOptimizerRefresh(250);
  } catch (_error) {
    scheduleDnsOptimizerRefresh(250);
  }
}

function writePrimaryDnsOption(sectionId, value) {
  uci.set("podkop", sectionId, this.option, value);
  uci.set("podkop", sectionId, "dns_failover_active_slot", "primary");
}

function configureDnsBenchmarkMultiValue(option) {
  option.display_size = 1;
  option.dropdown_size = 8;
  const renderWidget = option.renderWidget;
  option.renderWidget = function (...args) {
    const node = renderWidget.apply(this, args);
    node.classList.add("pdk-settings-multivalue");
    const list = node.querySelector("ul");
    const summary = document.createElement("span");
    summary.className = "pdk-settings-multivalue__summary";
    // Keep LuCI's hidden-value container as the last child: native saveValues
    // and getValue depend on that position. The menu itself is not replaced.
    node.insertBefore(summary, node.firstChild);
    // LuCI initially creates unchecked inputs even for li[selected]. Themes
    // can expose those inputs before openDropdown() synchronizes them.
    const syncChecks = () => {
      node.querySelectorAll("li[data-value]").forEach((item) => {
        const input = item.querySelector('input[type="checkbox"]');
        if (input) {
          input.checked = item.hasAttribute("selected");
          input.defaultChecked = input.checked;
        }
      });
      const selected = Array.from(list.querySelectorAll("li[data-value]"))
        .filter((item) => item.hasAttribute("selected"));
      const labels = selected.map((item) => {
        const index = this.keylist.indexOf(item.getAttribute("data-value"));
        return this.vallist[index] || item.getAttribute("data-value");
      });
      summary.textContent = ["dns_optimizer_protocols", "dns_optimizer_bootstrap_protocols"].includes(this.option)
        ? labels.join(", ") || "Не выбрано"
        : `Выбрано: ${selected.length} из ${this.keylist.length}`;
      summary.title = labels.join(", ");
    };
    syncChecks();
    node.addEventListener("cbi-dropdown-open", syncChecks);
    node.addEventListener("cbi-dropdown-change", () => {
      syncChecks();
      // LuCI cancels checkbox clicks. Browser cancelled-activation restores
      // the old checked property AFTER this synchronous change notification.
      // A new task (not a microtask) observes the final native selection.
      window.setTimeout(syncChecks, 0);
    });
    return node;
  };
}

function configureDnsServerChoices(option, protocolName, bootstrap = false) {
  const render = option.renderWidget;
  const choices = type => Object.fromEntries(Object.entries(main.getDnsServerOptionsForType(type, bootstrap))
    .filter(([dnsServer]) => bootstrap || candidateIsPrimaryEligible({dnsServer})));
  option.renderWidget = function(sectionId, optionIndex, cfgvalue) {
    const protocolOption = this.map.lookupOption?.(protocolName, sectionId)?.[0];
    const type = protocolOption?.formvalue(sectionId) || uci.get("podkop", sectionId, protocolName) || "udp";
    const values = choices(type);
    this.keylist = Object.keys(values); this.vallist = Object.values(values);
    if (protocolOption) {
      protocolOption.onchange = (_event, changedSection, nextType) => {
        const widget = this.getUIElement(changedSection);
        const nextChoices = choices(nextType);
        // Native LuCI APIs retain a saved/custom value; selecting a different
        // transport is never authority to overwrite the user's DNS address.
        widget?.clearChoices?.(false);
        widget?.addChoices?.(Object.keys(nextChoices), nextChoices);
      };
    }
    return render.call(this, sectionId, optionIndex, cfgvalue);
  };
}

function createSettingsContent(section) {
  injectDnsOptimizerStyles();
  section.tab("dns", "DNS");
  section.tab("benchmark", "Проверка DNS");
  section.tab("service", "Дополнительно");
  const settingsOption = (type, name, ...args) => {
    const tab = name.startsWith("dns_optimizer_") || name === "_dns_benchmark"
      ? "benchmark"
      : name.startsWith("dns_") || name.startsWith("secondary_") ||
          name === "bootstrap_dns_server" || name === "bootstrap_dns_type" || name === "_dns_failover_active"
        ? "dns"
        : "service";
    const option = section.taboption(tab, type, name, ...args);
    if (type === form.MultiValue) configureDnsBenchmarkMultiValue(option);
    return option;
  };
  let o = settingsOption(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.value("tcp", "DNS over TCP");
  o.default = "udp";
  o.rmempty = false;
  dnsOptimizerState.protocolOption = o;
  o.write = writePrimaryDnsOption;

  o = settingsOption(
    form.Value,
    "dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  dnsOptimizerState.dnsServerOption = o;
  configureDnsServerChoices(o, "dns_type");
  o.write = writePrimaryDnsOption;
  o.validate = function (section_id, value) {
    if (!candidateIsPrimaryEligible({ dnsServer: value })) {
      return "Yandex DNS можно использовать только как bootstrap DNS.";
    }
    const type = dnsOptimizerState.protocolOption?.formvalue(section_id) || uci.get("podkop", section_id, "dns_type") || "udp";
    const validation = main.validateDnsByType(value, type);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = settingsOption(form.ListValue, "bootstrap_dns_type", "Протокол bootstrap DNS");
  ["udp", "tcp", "doh", "dot"].forEach(type => o.value(type, type.toUpperCase()));
  o.default = "udp";
  o.rmempty = false;
  o.write = writePrimaryDnsOption;

  o = settingsOption(
    form.Value,
    "bootstrap_dns_server",
    _("Bootstrap DNS server"),
    _(
      "The DNS server used to look up the IP address of an upstream DNS server",
    ),
  );
  Object.entries(main.BOOTSTRAP_DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "77.88.8.8";
  o.rmempty = false;
  dnsOptimizerState.bootstrapDnsServerOption = o;
  configureDnsServerChoices(o, "bootstrap_dns_type", true);
  o.write = writePrimaryDnsOption;
  o.validate = function (section_id, value) {
    const typeOption = this.map.lookupOption("bootstrap_dns_type", section_id)?.[0];
    const type = typeOption?.formvalue(section_id) || uci.get("podkop", section_id, "bootstrap_dns_type") || "udp";
    const validation = main.validateDnsByType(value, type, true);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = settingsOption(
    form.Flag,
    "dns_failover_enabled",
    "Автоматический резервный DNS",
    "Хранит две полные пары DNS. После двух последовательных отказов активной пары Podkop проверит резервную, переключится на неё и повторно проверит sing-box и FakeIP. Автоматического возврата к основной паре нет, чтобы исключить постоянные переключения.",
  );
  o.default = "0";
  o.rmempty = false;
  dnsOptimizerState.failoverEnabledOption = o;

  o = settingsOption(form.DummyValue, "_dns_failover_active", "Сейчас активна");
  o.depends("dns_failover_enabled", "1");
  o.cfgvalue = function (sectionId) {
    return uci.get("podkop", sectionId, "dns_failover_active_slot") ===
      "secondary"
      ? "Резервная пара"
      : "Предпочтительная пара";
  };

  o = settingsOption(
    form.ListValue,
    "secondary_dns_type",
    "Протокол резервного DNS",
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.value("tcp", "DNS over TCP");
  o.default = "udp";
  o.rmempty = false;
  o.depends("dns_failover_enabled", "1");
  dnsOptimizerState.secondaryProtocolOption = o;

  o = settingsOption(
    form.Value,
    "secondary_dns_server",
    "Резервный DNS-сервер",
    "Независимый основной DNS, который будет активирован только после подтверждённого отказа первой пары.",
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.rmempty = false;
  o.depends("dns_failover_enabled", "1");
  dnsOptimizerState.secondaryDnsServerOption = o;
  configureDnsServerChoices(o, "secondary_dns_type");
  o.validate = function (section_id, value) {
    if (!candidateIsPrimaryEligible({ dnsServer: value })) {
      return "Yandex DNS можно использовать только как bootstrap DNS.";
    }
    const type = dnsOptimizerState.secondaryProtocolOption?.formvalue(section_id) || uci.get("podkop", section_id, "secondary_dns_type") || "udp";
    const validation = main.validateDnsByType(value, type);
    return validation.valid ? true : validation.message;
  };

  o = settingsOption(form.ListValue, "secondary_bootstrap_dns_type", "Протокол резервного bootstrap DNS");
  ["udp", "tcp", "doh", "dot"].forEach(type => o.value(type, type.toUpperCase()));
  o.default = "udp";
  o.rmempty = false;
  o.depends("dns_failover_enabled", "1");

  o = settingsOption(
    form.Value,
    "secondary_bootstrap_dns_server",
    "Bootstrap резервной пары",
    "Bootstrap DNS для резервного DoH/DoT. Лучше выбирать другого провайдера, чем у первой пары.",
  );
  Object.entries(main.BOOTSTRAP_DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "1.1.1.1";
  o.rmempty = false;
  o.depends("dns_failover_enabled", "1");
  dnsOptimizerState.secondaryBootstrapDnsServerOption = o;
  configureDnsServerChoices(o, "secondary_bootstrap_dns_type", true);
  o.validate = function (section_id, value) {
    const typeOption = this.map.lookupOption("secondary_bootstrap_dns_type", section_id)?.[0];
    const type = typeOption?.formvalue(section_id) || uci.get("podkop", section_id, "secondary_bootstrap_dns_type") || "udp";
    const validation = main.validateDnsByType(value, type, true);
    return validation.valid ? true : validation.message;
  };

  o = settingsOption(
    form.MultiValue,
    "dns_optimizer_protocols",
    "Режимы для проверки",
    "Протоколы для бенчмарка основного DNS. Основной и bootstrap DNS измеряются отдельно; перед применением проверяется выбранная пара.",
  );
  o.value("udp", "UDP");
  o.value("doh", "DoH");
  o.value("dot", "DoT");
  o.value("tcp", "TCP");
  o.default = ["udp", "doh", "dot"];
  o.rmempty = false;
  o.cfgvalue = function (sectionId) {
    const value = uci.get("podkop", sectionId, "dns_optimizer_protocols");
    return value == null || (Array.isArray(value) && !value.length)
      ? ["udp", "doh", "dot"]
      : value;
  };
  dnsOptimizerState.benchmarkProtocolsOption = o;

  o = settingsOption(
    form.MultiValue,
    "dns_optimizer_candidates",
    "DNS для проверки",
    "Выберите основной каталог для теста. Меньше кандидатов — быстрее и точнее сравнение. Пользовательские и WAN DNS не становятся автоматической рекомендацией.",
  );
  NORMAL_DNS_OPTIMIZER_CANDIDATES.forEach(([value, label]) =>
    o.value(value, label),
  );
  o.default = DEFAULT_NORMAL_DNS_OPTIMIZER_CANDIDATES;
  o.rmempty = false;
  o.cfgvalue = function (sectionId) {
    const configured = uci.get(
      "podkop",
      sectionId,
      "dns_optimizer_candidates",
    );
    const selected = Array.isArray(configured)
      ? configured
      : String(configured || "")
          .split(/\s+/)
          .filter(Boolean);
    const allowed = new Set(
      NORMAL_DNS_OPTIMIZER_CANDIDATES.map(([value]) => value),
    );
    const filtered = selected.filter((value) => allowed.has(value));
    return filtered.length
      ? filtered
      : DEFAULT_NORMAL_DNS_OPTIMIZER_CANDIDATES;
  };

  o = settingsOption(form.MultiValue, "dns_optimizer_bootstrap_protocols", "Протоколы проверки bootstrap DNS");
  ["udp", "tcp", "doh", "dot"].forEach(type => o.value(type, type.toUpperCase()));
  o.default = ["udp"];
  o.rmempty = false;

  o = settingsOption(
    form.MultiValue,
    "dns_optimizer_bootstrap_candidates",
    "Bootstrap DNS для проверки",
    "Выберите bootstrap-кандидатов. В универсальную пару входят только публичные нефильтрующие адреса.",
  );
  BOOTSTRAP_DNS_OPTIMIZER_CANDIDATES.forEach(([value, label]) =>
    o.value(value, label),
  );
  o.default = DEFAULT_BOOTSTRAP_DNS_OPTIMIZER_CANDIDATES;
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "dns_optimizer_include_current",
    "Сравнивать текущую пару",
    "Добавляет текущие основной и bootstrap DNS в таблицу только для сравнения.",
  );
  o.default = "1";
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "dns_optimizer_include_wan",
    "Сравнивать DNS провайдера",
    "Добавляет полученные от WAN DNS в UDP-тест. Они никогда не выбираются как универсальная рекомендация.",
  );
  o.default = "0";
  o.rmempty = false;

  const customDnsOptions = [
    ["udp", "dns_optimizer_custom_udp", "Свои DNS для UDP"],
    ["doh", "dns_optimizer_custom_doh", "Свои DNS для DoH"],
    ["dot", "dns_optimizer_custom_dot", "Свои DNS для DoT"],
    ["tcp", "dns_optimizer_custom_tcp", "Свои DNS для TCP"],
  ];
  customDnsOptions.forEach(([protocol, optionName, label]) => {
    const customOption = settingsOption(
      form.DynamicList,
      optionName,
      label,
      "Адреса сохраняются в настройках и появляются в тесте как варианты только для сравнения и ручной установки.",
    );
    customOption.depends({
      dns_optimizer_protocols: protocol,
      "!contains": true,
    });
    customOption.rmempty = true;
    customOption.placeholder =
      protocol === "udp"
        ? "1.2.3.4"
        : protocol === "doh"
          ? "dns.example/dns-query"
          : "dns.example";
    customOption.validate = function (section_id, value) {
      if (!value) {
        return true;
      }
      const validation =
        main.validateDnsByType(value, protocol);
      return validation.valid ? true : validation.message;
    };
  });

  o = settingsOption(form.DummyValue, "_dns_benchmark", "Бенчмарк DNS");
  o.rawhtml = true;
  o.renderWidget = function () {
    return dnsBenchmark.renderOpenButton(this.map);
  };

  o = settingsOption(
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _("TTL must be a positive number");
    }

    return true;
  };

  o = settingsOption(
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ["wan", "phy0-ap0", "phy1-ap0", "pppoe-wan"];
    if (blocked.includes(value)) {
      return false;
    }

    // Try to find the device object by its name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Check the type of the device
    const type = device.getType();

    // Consider any Wi-Fi / wireless / wlan device as invalid
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = settingsOption(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = ["br-lan"];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Reject lan*
    if (value.startsWith("lan")) {
      return false;
    }

    // Reject tun*, wg*, vpn*, awg*, oc*
    if (
      value.startsWith("tun") ||
      value.startsWith("wg") ||
      value.startsWith("vpn") ||
      value.startsWith("awg") ||
      value.startsWith("oc")
    ) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = settingsOption(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = settingsOption(
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading podkop after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    return true;
  };

  o = settingsOption(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.ListValue,
    "update_interval",
    _("List Update Frequency"),
    _("Select how often the domain or subnet lists are updated automatically"),
  );
  Object.entries(main.UPDATE_INTERVAL_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "1d";
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "download_lists_via_proxy",
    _("Download Lists via Proxy/VPN"),
    _("Downloading all lists via specific Proxy/VPN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download Lists via specific proxy section"),
    _("Downloading all lists via specific Proxy/VPN"),
  );

  o.rmempty = false;
  o.depends("download_lists_via_proxy", "1");
  o.cfgvalue = function (section_id) {
    return uci.get("podkop", section_id, "download_lists_via_proxy_section");
  };
  o.load = function () {
    const sections = this.map?.data?.state?.values?.podkop ?? {};

    this.keylist = [];
    this.vallist = [];

    for (const secName in sections) {
      const sec = sections[secName];
      if (
        sec[".type"] === "section" &&
        sec["connection_type"] !== "block" &&
        sec["connection_type"] !== "exclusion"
      ) {
        this.keylist.push(secName);
        this.vallist.push(secName);
      }
    }

    return Promise.resolve();
  };

  o = settingsOption(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Podkop will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Флеш-память (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "Оперативная память (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = settingsOption(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "Оперативная память (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Флеш-память (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    if (!value.startsWith("/")) {
      return _("Path must be absolute (start with /)");
    }

    if (!value.endsWith("cache.db")) {
      return _("Path must end with cache.db");
    }

    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2) {
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    }

    return true;
  };

  o = settingsOption(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", "Трассировка");
  o.value("debug", "Отладка");
  o.value("info", "Информация");
  o.value("warn", "Предупреждения");
  o.value("error", "Ошибки");
  o.value("fatal", "Критические ошибки");
  o.value("panic", "Аварии");
  o.default = "warn";
  o.rmempty = false;

  o = settingsOption(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = settingsOption(
    form.DynamicList,
    "routing_excluded_ips",
    _("Routing Excluded IPs"),
    _("Specify a local IP address to be excluded from routing"),
  );
  o.placeholder = "IP";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateIPV4(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };
}

const EntryPoint = {
  createSettingsContent,
};

return baseclass.extend(EntryPoint);
