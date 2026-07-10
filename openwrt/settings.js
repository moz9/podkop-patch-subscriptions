"use strict";
"require form";
"require uci";
"require fs";
"require baseclass";
"require tools.widgets as widgets";
"require view.podkop.main as main";

const DNS_OPTIMIZER_COMMAND = "/usr/bin/podkop-dns-optimizer";
const dnsOptimizerState = {
  node: null,
  status: null,
  protocolOption: null,
  pollTimer: null,
  reloadScheduled: false,
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
      border-left: 3px solid #2ebd85;
      padding: 8px 10px;
      margin: 10px 0;
      background: rgba(46, 189, 133, 0.08);
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
      min-width: 690px;
      border-collapse: collapse;
      table-layout: fixed;
    }
    .pdk-dns-optimizer__table th,
    .pdk-dns-optimizer__table td {
      padding: 7px 8px;
      border-bottom: 1px solid rgba(127, 127, 127, 0.18);
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    .pdk-dns-optimizer__table th:nth-child(1) { width: 23%; }
    .pdk-dns-optimizer__table th:nth-child(2) { width: 12%; }
    .pdk-dns-optimizer__table th:nth-child(3) { width: 12%; }
    .pdk-dns-optimizer__table th:nth-child(4) { width: 12%; }
    .pdk-dns-optimizer__table th:nth-child(5) { width: 18%; }
    .pdk-dns-optimizer__table th:nth-child(6) { width: 23%; }
    .pdk-dns-optimizer__row--recommended {
      background: rgba(46, 189, 133, 0.08);
    }
    .pdk-dns-optimizer__row--current td:first-child::after {
      content: "Текущий";
      display: inline-block;
      margin-left: 6px;
      padding: 1px 5px;
      border: 1px solid rgba(95, 157, 247, 0.6);
      border-radius: 4px;
      color: #79adf8;
      font-size: 11px;
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
    @media (max-width: 720px) {
      .pdk-dns-optimizer { padding: 10px; }
      .pdk-dns-optimizer__actions { width: 100%; }
      .pdk-dns-optimizer__actions button { flex: 1 1 88px; }
    }
  `;
  document.head.appendChild(style);
}

function protocolLabel(protocol) {
  return ({ udp: "UDP", doh: "DoH", dot: "DoT" })[protocol] || protocol;
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
    benchmark_complete: "Подбор завершён. Рекомендация рассчитана по стабильности, задержке и совместимости пары.",
    no_reliable_dns: "Ни одна пара не прошла все проверки. Настройки не изменены.",
    saving_previous_dns: "Сохраняем предыдущие DNS-настройки для быстрого отката…",
    restarting_podkop: "Устанавливаем DNS и перезапускаем Podkop…",
    validating_dns: "Проверяем sing-box, DNS, FakeIP и dnsmasq…",
    rolling_back: "Проверка не пройдена. Автоматически возвращаем прежние DNS…",
    apply_complete: "DNS установлен и полностью проверен. Страница будет обновлена.",
    apply_failed_rolled_back: "Новая пара не прошла проверку. Прежние DNS автоматически восстановлены.",
    apply_failed_rollback_failed: "Не удалось применить DNS и автоматический откат завершился ошибкой.",
    bootstrap_incompatible: "Выбранный bootstrap DNS не разрешает адрес основного DNS.",
    invalid_recommendation: "Результат подбора устарел. Запустите проверку ещё раз.",
    backup_failed: "Не удалось сохранить прежние DNS. Применение отменено.",
    no_previous_dns: "Нет сохранённых DNS для отката.",
    rollback_complete: "Предыдущие DNS восстановлены и проверены. Страница будет обновлена.",
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
    throw new Error((response?.stderr || "Команда не вернула результат").trim());
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
      class: `cbi-button{className}`,
      disabled: disabled || undefined,
      click: onClick,
    },
    text,
  );
}

function resultClass(result) {
  if (result.reliable) {
    return result.jitterMs <= 30 ? "pdk-dns-optimizer__ok" : "pdk-dns-optimizer__warn";
  }
  return "pdk-dns-optimizer__bad";
}

function resultVerdict(result) {
  if (result.reliable && result.jitterMs <= 30) {
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
  return "Есть потери или тайм-ауты";
}

function renderRecommendation(status) {
  const result = status.recommendation;
  if (!result) {
    return E("div");
  }

  return E("div", { class: "pdk-dns-optimizer__recommendation" }, [
    E("strong", {}, `Рекомендуется:{result.provider} (${protocolLabel(result.protocol)})`),
    E("div", { class: "pdk-dns-optimizer__pair" }, [
      E("span", {}, [E("b", {}, "Основной: "), result.dnsServer]),
      E("span", {}, [E("b", {}, "Bootstrap: "), `${result.bootstrapProvider} (${result.bootstrapDnsServer})`]),
    ]),
    E(
      "div",
      { class: "pdk-dns-optimizer__detail" },
      `${result.successCount}/${result.totalQueries} успешных запросов, медиана{result.medianMs} мс, разброс ${result.jitterMs} мс; bootstrap ${result.bootstrapMedianMs} мс. NXDOMAIN не подменяется. ${profileLabel(result.profile)}.`,
    ),
  ]);
}

function renderMainResults(status) {
  const results = Array.isArray(status.results) ? status.results : [];
  if (!results.length) {
    return E("div");
  }

  const rows = results.map((result) => {
    const classes = [];
    if (status.recommendation?.id === result.id) {
      classes.push("pdk-dns-optimizer__row--recommended");
    }
    if (status.current?.dnsServer === result.dnsServer) {
      classes.push("pdk-dns-optimizer__row--current");
    }

    return E("tr", { class: classes.join(" ") }, [
      E("td", {}, [E("b", {}, result.provider), E("div", { class: "pdk-dns-optimizer__detail" }, result.dnsServer)]),
      E("td", { class: resultClass(result) }, `${result.successRate}%`),
      E("td", {}, result.medianMs ? `${result.medianMs} мс` : "—"),
      E("td", {}, result.jitterMs || result.reliable ? `${result.jitterMs} мс` : "—"),
      E("td", {}, profileLabel(result.profile)),
      E("td", { class: resultClass(result) }, resultVerdict(result)),
    ]);
  });

  return E("div", { class: "pdk-dns-optimizer__table-wrap" }, [
    E("table", { class: "pdk-dns-optimizer__table" }, [
      E("thead", {}, [
        E("tr", {}, [
          E("th", {}, "Основной DNS"),
          E("th", {}, "Успех"),
          E("th", {}, "Медиана"),
          E("th", {}, "Разброс"),
          E("th", {}, "Особенности"),
          E("th", {}, "Оценка"),
        ]),
      ]),
      E("tbody", {}, rows),
    ]),
  ]);
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
      E("table", { class: "pdk-dns-optimizer__table" }, [
        E("thead", {}, [
          E("tr", {}, [
            E("th", {}, "Bootstrap DNS"),
            E("th", {}, "Адрес"),
            E("th", {}, "Успех"),
            E("th", {}, "Медиана"),
            E("th", {}, "Разброс"),
            E("th", {}, "Тип"),
          ]),
        ]),
        E(
          "tbody",
          {},
          results.map((result) =>
            E("tr", {}, [
              E("td", {}, result.provider),
              E("td", {}, result.server),
              E("td", { class: resultClass(result) }, `${result.successRate}%`),
              E("td", {}, result.medianMs ? `${result.medianMs} мс` : "—"),
              E("td", {}, result.jitterMs || result.reliable ? `${result.jitterMs} мс` : "—"),
              E("td", {}, profileLabel(result.profile)),
            ]),
          ),
        ),
      ]),
    ]),
  ]);
}

function schedulePageReload() {
  if (dnsOptimizerState.reloadScheduled) {
    return;
  }
  dnsOptimizerState.reloadScheduled = true;
  window.setTimeout(() => window.location.reload(), 2500);
}

function renderDnsOptimizer() {
  injectDnsOptimizerStyles();
  const status = dnsOptimizerState.status || {
    state: "idle",
    message: "idle",
    progress: 0,
  };
  const running = status.state === "running";
  const changing = running && (status.action === "apply" || status.action === "rollback");
  const recommendation = status.recommendation;

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
          "Проверяет реальные DNS-запросы с роутера и подбирает совместимую пару основного и bootstrap DNS для выбранного выше протокола.",
        ),
      ]),
      E("div", { class: "pdk-dns-optimizer__actions" }, [
        renderActionButton("Проверить DNS", "cbi-button-action", running, startDnsBenchmark),
        renderActionButton(
          "Установить",
          "cbi-button-apply",
          running || !recommendation,
          applyRecommendedDns,
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
      E("span", { style: `width:{Math.max(0, Math.min(100, status.progress || 0))}%` }),
    ]),
    renderRecommendation(status),
    renderMainResults(status),
    renderBootstrapResults(status),
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
  updateDnsOptimizerNode();

  if (dnsOptimizerState.status.state === "running") {
    dnsOptimizerState.pollTimer = window.setTimeout(
      refreshDnsOptimizerStatus,
      1000,
    );
  } else if (
    dnsOptimizerState.status.state === "success" &&
    ["apply", "rollback"].includes(dnsOptimizerState.status.action)
  ) {
    schedulePageReload();
  }
}

async function startDnsBenchmark() {
  const protocol =
    dnsOptimizerState.protocolOption?.formvalue("settings") ||
    uci.get("podkop", "settings", "dns_type") ||
    "udp";
  dnsOptimizerState.status = {
    state: "running",
    action: "benchmark",
    message: "starting",
    progress: 0,
  };
  updateDnsOptimizerNode();

  try {
    const result = await callDnsOptimizer(["benchmark_start", protocol]);
    if (!result.success) {
      if (result.error === "busy") {
        dnsOptimizerState.pollTimer = window.setTimeout(
          refreshDnsOptimizerStatus,
          250,
        );
        return;
      }
      throw new Error(result.error || "start_failed");
    }
    dnsOptimizerState.pollTimer = window.setTimeout(
      refreshDnsOptimizerStatus,
      500,
    );
  } catch (error) {
    dnsOptimizerState.status = {
      state: "error",
      message: error.message === "busy" ? "starting" : "worker_stopped",
      progress: 100,
    };
    updateDnsOptimizerNode();
  }
}

async function applyRecommendedDns() {
  const recommendation = dnsOptimizerState.status?.recommendation;
  if (!recommendation) {
    return;
  }
  dnsOptimizerState.status = {
    state: "running",
    action: "apply",
    message: "saving_previous_dns",
    progress: 5,
  };
  updateDnsOptimizerNode();

  try {
    const result = await callDnsOptimizer([
      "apply_start",
      recommendation.protocol,
      recommendation.id,
      recommendation.bootstrapDnsServer,
    ]);
    if (!result.success) {
      if (result.error === "busy") {
        dnsOptimizerState.pollTimer = window.setTimeout(
          refreshDnsOptimizerStatus,
          250,
        );
        return;
      }
      throw new Error(result.error || "start_failed");
    }
    dnsOptimizerState.pollTimer = window.setTimeout(
      refreshDnsOptimizerStatus,
      500,
    );
  } catch (_error) {
    dnsOptimizerState.status = {
      state: "error",
      message: "worker_stopped",
      progress: 100,
    };
    updateDnsOptimizerNode();
  }
}

async function rollbackDns() {
  dnsOptimizerState.status = {
    state: "running",
    action: "rollback",
    message: "rolling_back",
    progress: 5,
  };
  updateDnsOptimizerNode();

  try {
    const result = await callDnsOptimizer(["rollback_start"]);
    if (!result.success) {
      if (result.error === "busy") {
        dnsOptimizerState.pollTimer = window.setTimeout(
          refreshDnsOptimizerStatus,
          250,
        );
        return;
      }
      throw new Error(result.error || "start_failed");
    }
    dnsOptimizerState.pollTimer = window.setTimeout(
      refreshDnsOptimizerStatus,
      500,
    );
  } catch (_error) {
    dnsOptimizerState.status = {
      state: "error",
      message: "rollback_failed",
      progress: 100,
    };
    updateDnsOptimizerNode();
  }
}

function createSettingsContent(section) {
  let o = section.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;
  dnsOptimizerState.protocolOption = o;

  o = section.option(
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
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
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
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(form.DummyValue, "_dns_optimizer");
  o.rawhtml = true;
  o.cfgvalue = () => {
    if (dnsOptimizerState.pollTimer) {
      window.clearTimeout(dnsOptimizerState.pollTimer);
      dnsOptimizerState.pollTimer = null;
    }
    dnsOptimizerState.node = renderDnsOptimizer();
    window.setTimeout(refreshDnsOptimizerStatus, 0);
    return dnsOptimizerState.node;
  };

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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
    if (
        value.startsWith("lan")
    ) {
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

  o = section.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _("Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall."),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _("Secret key for authenticating remote access to YACD when WAN access is enabled."),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download Lists via Proxy/VPN"),
    _("Downloading all lists via specific Proxy/VPN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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
      if (sec[".type"] === "section" && sec['connection_type'] !== 'block' && sec['connection_type'] !== 'exclusion') {
        this.keylist.push(secName);
        this.vallist.push(secName);
      }
    }

    return Promise.resolve();
  };

  o = section.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Podkop will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Flash (/usr/share/sing-box/cache.db)",
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

  o = section.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _(
      "Select the log level for sing-box",
    ),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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
