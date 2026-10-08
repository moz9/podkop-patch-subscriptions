"use strict";
"require form";
"require baseclass";
"require ui";
"require uci";
"require tools.widgets as widgets";
"require view.podkop.main as main";

function createSectionContent(section) {
  // Native GridSection.handleModalSave() silently catches failures from
  // save(null, true). Keep the modal and draft visible and show the failure.
  section.handleModalSave = function (modalMap, event) {
    let activeMap = modalMap;
    let saveTasks = activeMap.save(null, true);
    while (activeMap.parent) {
      const parent = activeMap.parent;
      activeMap = parent;
      saveTasks = saveTasks.then(() => parent.load()).then(() => parent.reset());
    }
    return saveTasks.then(() => this.handleModalCancel(modalMap, event, true)).catch(error => {
      const previous = modalMap.root?.querySelector(".pdk-section-save-error");
      if (previous) previous.remove();
      const detail = error instanceof TypeError && error.message
        ? error.message : "Проверьте поля и соединение с маршрутизатором, затем повторите.";
      modalMap.root?.prepend(E("div", {class:"alert-message warning pdk-section-save-error", role:"alert"},
        "Не удалось сохранить секцию. " + detail));
    });
  };
  section.tab("connection", "Подключение");
  section.tab("checking", "Проверка узлов");
  section.tab("lists", "Списки");
  section.tab("advanced", "Дополнительно");

  const listFields = new Set([
    "community_lists", "user_domain_list_type", "user_domains", "user_domains_text",
    "user_subnet_list_type", "user_subnets", "user_subnets_text", "local_domain_lists",
    "local_subnet_lists", "remote_domain_lists", "remote_subnet_lists",
  ]);
  const checkingFields = new Set([
    "urltest_check_interval", "urltest_tolerance",
    "urltest_testing_url",
  ]);
  const advancedFields = new Set([
    "fully_routed_ips", "mixed_proxy_enabled", "mixed_proxy_port", "resolve_real_ip_for_routing",
  ]);
  const modalOption = (type, name, ...args) => {
    const field = section.taboption(
      listFields.has(name) ? "lists" : checkingFields.has(name) ? "checking" :
        advancedFields.has(name) ? "advanced" : "connection",
      type, name, ...args,
    );
    field.modalonly = true;
    return field;
  };
  const configValue = (sectionId, name) => uci.get("podkop", sectionId, name);
  const countValues = value => Array.isArray(value) ? value.filter(Boolean).length :
    typeof value === "string" ? value.trim().split(/\s+/).filter(Boolean).length : 0;
  const summary = (name, title, value) => {
    const column = section.option(form.DummyValue, name, title);
    column.modalonly = false;
    column.cfgvalue = value;
  };
  summary("_overview_type", "Тип", sectionId => {
    const connection = configValue(sectionId, "connection_type");
    if (connection === "vpn") return "VPN";
    if (connection === "block") return "Блокировка";
    if (connection === "exclusion") return "Исключение";
    const type = configValue(sectionId, "proxy_config_type");
    return "Прокси · " + ({url: "Ссылка", selector: "Селектор", urltest: "URLTest",
      subscription_urltest: "Микс", outbound: "JSON"}[type] || "—");
  });
  summary("_overview_sources", "Источники", sectionId => {
    const connection = configValue(sectionId, "connection_type");
    if (connection === "vpn") return "Интерфейс: " + (configValue(sectionId, "interface") || "—");
    if (connection !== "proxy") return "—";
    const type = configValue(sectionId, "proxy_config_type");
    if (type === "subscription_urltest") {
      const sources = countValues(configValue(sectionId, "subscription_url"));
      const manual = countValues(configValue(sectionId, "urltest_proxy_links"));
      const selected = configValue(sectionId, "subscription_selection_mode") === "selected"
        ? " · выбрано: " + countValues(configValue(sectionId, "subscription_selected_link_ids")) : "";
      return "Подписок: " + sources + " · ссылок: " + manual + selected;
    }
    if (type === "urltest") return "Узлов: " + countValues(configValue(sectionId, "urltest_proxy_links"));
    if (type === "selector") return "Узлов: " + countValues(configValue(sectionId, "selector_proxy_links"));
    return type === "url" ? "Один адрес" : type === "outbound" ? "JSON" : "—";
  });
  summary("_overview_lists", "Списки", sectionId => {
    const count = ["community_lists", "user_domains", "user_subnets", "local_domain_lists",
      "local_subnet_lists", "remote_domain_lists", "remote_subnet_lists"].reduce(
      (total, name) => total + countValues(configValue(sectionId, name)), 0);
    return count ? "Элементов: " + count : "Нет";
  });

  function hasListValue(value) {
    if (Array.isArray(value)) {
      return value.some((item) => item != null && String(item).trim() !== "");
    }

    return value != null && String(value).trim() !== "";
  }

  let o = modalOption(
    form.ListValue,
    "connection_type",
    _("Connection Type"),
    _("Select between VPN and Proxy connection methods for traffic routing"),
  );
  o.value("proxy", "Прокси");
  o.value("vpn", "VPN");
  o.value("block", "Блокировка");
  o.value("exclusion", "Исключение");

  o = modalOption(
    form.ListValue,
    "proxy_config_type",
    _("Configuration Type"),
    _("Select how to configure the proxy"),
  );
  o.value("url", _("Connection URL"));
  o.value("selector", _("Selector"));
  o.value("urltest", _("URLTest"));
  o.value("subscription_urltest", "\u041c\u0438\u043a\u0441");
  o.value("outbound", _("Outbound Config"));
  o.default = "url";
  o.depends("connection_type", "proxy");

  o = modalOption(
    form.TextValue,
    "proxy_string",
    _("Proxy Configuration URL"),
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links")
  );
  o.depends("proxy_config_type", "url");
  o.rows = 5;
  // Enable soft wrapping for multi-line proxy URLs (e.g., for URLTest proxy links)
  o.wrap = "soft";
  // Render as a textarea to allow multiple proxy URLs/configs
  o.textarea = true;
  o.rmempty = false;
  o.sectionDescriptions = new Map();
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "subscription_url",
    _("Subscription URLs"),
    _("HTTP/HTTPS subscription links with proxy URLs")
  );
  o.depends("proxy_config_type", "subscription_urltest");
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.ListValue,
    "subscription_update_interval",
    _("Subscription Update Interval"),
    _("How often to refresh the subscription cache")
  );
  o.value("10m", _("Every 10 minutes"));
  o.value("30m", _("Every 30 minutes"));
  o.value("1h", _("Every 1 hour"));
  o.value("3h", _("Every 3 hours"));
  o.value("6h", _("Every 6 hours"));
  o.value("12h", _("Every 12 hours"));
  o.value("1d", _("Every day"));
  o.default = "1h";
  o.depends("proxy_config_type", "subscription_urltest");

  o = modalOption(
    form.TextValue,
    "outbound_json",
    _("Outbound Configuration"),
    _("Enter complete outbound configuration in JSON format"),
  );
  o.depends("proxy_config_type", "outbound");
  o.rows = 10;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateOutboundJson(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "selector_proxy_links",
    _("Selector Proxy Links"),
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links")
  );
  o.depends("proxy_config_type", "selector");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "urltest_proxy_links",
    "\u041f\u0440\u043e\u043a\u0441\u0438-\u0441\u0441\u044b\u043b\u043a\u0438",
    _("vless://, ss://, trojan://, socks4/5://, hy2/hysteria2:// links")
  );
  o.depends("proxy_config_type", "urltest");
  o.depends("proxy_config_type", "subscription_urltest");
  o.rmempty = true;
  const baseUrltestProxyLinksParse = o.parse;
  o.parse = function (section_id) {
    // GridSection copies options into a NamedSection modal. The original
    // options are not rendered, so read the sibling widgets from this map.
    const modalValue = name => {
      const match = this.map.lookupOption(name, section_id);
      return match ? match[0].formvalue(match[1]) : null;
    };
    const proxyConfigType = modalValue("proxy_config_type");
    const proxyLinks = this.formvalue(section_id);
    const subscriptionUrls = modalValue("subscription_url");

    if (this.isActive(section_id) && !hasListValue(proxyLinks)) {
      if (proxyConfigType === "urltest") {
        const title = this.stripTags(this.title).trim();
        return Promise.reject(
          new TypeError(
            _('Option "%s" must not be empty.').format(title || this.option)
          )
        );
      }

      if (
        proxyConfigType === "subscription_urltest" &&
        !hasListValue(subscriptionUrls)
      ) {
        return Promise.reject(
          new TypeError(
            "\u0417\u0430\u043f\u043e\u043b\u043d\u0438\u0442\u0435 URL \u043f\u043e\u0434\u043f\u0438\u0441\u043e\u043a \u0438\u043b\u0438 \u041f\u0440\u043e\u043a\u0441\u0438-\u0441\u0441\u044b\u043b\u043a\u0438 \u0434\u043b\u044f \u0440\u0435\u0436\u0438\u043c\u0430 \u041c\u0438\u043a\u0441."
          )
        );
      }
    }

    return baseUrltestProxyLinksParse.call(this, section_id);
  };
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateProxyUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.ListValue,
    "urltest_check_interval",
    _("URLTest Check Interval"),
    _("The interval between connectivity tests")
  );
  o.value("30s", _("Every 30 seconds"));
  o.value("1m", _("Every 1 minute"));
  o.value("3m", _("Every 3 minutes"));
  o.value("5m", _("Every 5 minutes"));
  o.default = "3m";
  o.depends("proxy_config_type", "urltest");
  o.depends("proxy_config_type", "subscription_urltest");

  o = modalOption(
    form.Value,
    "urltest_tolerance",
    _("URLTest Tolerance"),
    _("The maximum difference in response times (ms) allowed when comparing servers")
  );
  o.default = "50";
  o.rmempty = false;
  o.depends("proxy_config_type", "urltest");
  o.depends("proxy_config_type", "subscription_urltest");
  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const parsed = parseFloat(value);

    if (/^[0-9]+$/.test(value) && !isNaN(parsed) && isFinite(parsed) && parsed >= 50 && parsed <= 1000) {
      return true;
    }

    return _('Must be a number in the range of 50 - 1000');
  };

  o = modalOption(
    form.Value,
    "urltest_testing_url",
    _("URLTest Testing URL"),
    _("The URL used to test server connectivity")
  );
  o.value("https://www.gstatic.com/generate_204", "https://www.gstatic.com/generate_204 (Google)");
  o.value("https://cp.cloudflare.com/generate_204", "https://cp.cloudflare.com/generate_204 (Cloudflare)");
  o.value("https://captive.apple.com", "https://captive.apple.com (Apple)");
  o.value("https://connectivity-check.ubuntu.com", "https://connectivity-check.ubuntu.com (Ubuntu)")
  o.default = "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.depends("proxy_config_type", "urltest");
  o.depends("proxy_config_type", "subscription_urltest");

  o.validate = function (section_id, value) {
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.Flag,
    "enable_udp_over_tcp",
    _("UDP over TCP"),
    _("Applicable for SOCKS and Shadowsocks proxy"),
  );
  o.default = "0";
  o.depends("connection_type", "proxy");
  o.rmempty = false;

  o = modalOption(
    widgets.DeviceSelect,
    "interface",
    _("Network Interface"),
    _("Select network interface for VPN connection"),
  );
  o.depends("connection_type", "vpn");
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = [
      "br-lan",
      "eth0",
      "eth1",
      "wan",
      "phy0-ap0",
      "phy1-ap0",
      "pppoe-wan",
      "lan",
    ];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
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

  o = modalOption(
    form.Flag,
    "domain_resolver_enabled",
    _("Domain Resolver"),
    _("Enable built-in DNS resolver for domains handled by this section"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "vpn");

  o = modalOption(
    form.ListValue,
    "domain_resolver_dns_type",
    _("DNS Protocol Type"),
    _("Select the DNS protocol type for the domain resolver"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");

  o = modalOption(
    form.Value,
    "domain_resolver_dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.depends("domain_resolver_enabled", "1");
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "community_lists",
    _("Community Lists"),
    _("Select a predefined list for routing") +
      ' <a href="https://github.com/itdoginfo/allow-domains" target="_blank">github.com/itdoginfo/allow-domains</a>',
  );
  o.placeholder = "Список сервисов";
  Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.rmempty = true;
  let lastValues = [];
  let isProcessing = false;

  o.onchange = function (ev, section_id, value) {
    if (isProcessing) return;
    isProcessing = true;

    try {
      const values = Array.isArray(value) ? value : [value];
      let newValues = [...values];
      let notifications = [];

      const selectedRegionalOptions = main.REGIONAL_OPTIONS.filter((opt) =>
        newValues.includes(opt),
      );

      if (selectedRegionalOptions.length > 1) {
        const lastSelected =
          selectedRegionalOptions[selectedRegionalOptions.length - 1];
        const removedRegions = selectedRegionalOptions.slice(0, -1);
        newValues = newValues.filter(
          (v) => v === lastSelected || !main.REGIONAL_OPTIONS.includes(v),
        );
        notifications.push(
          E("p", {}, [
            E("strong", {}, _("Regional options cannot be used together")),
            E("br"),
            _(
              "Warning: %s cannot be used together with %s. Previous selections have been removed.",
            ).format(removedRegions.join(", "), lastSelected),
          ]),
        );
      }

      if (newValues.includes("russia_inside")) {
        const removedServices = newValues.filter(
          (v) => !main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
        );
        if (removedServices.length > 0) {
          newValues = newValues.filter((v) =>
            main.ALLOWED_WITH_RUSSIA_INSIDE.includes(v),
          );
          notifications.push(
            E("p", { class: "alert-message warning" }, [
              E("strong", {}, _("Russia inside restrictions")),
              E("br"),
              _(
                "Warning: Russia inside can only be used with %s. %s already in Russia inside and have been removed from selection.",
              ).format(
                main.ALLOWED_WITH_RUSSIA_INSIDE.map(
                  (key) => main.DOMAIN_LIST_OPTIONS[key],
                )
                  .filter((label) => label !== "Russia inside")
                  .join(", "),
                removedServices.join(", "),
              ),
            ]),
          );
        }
      }

      if (JSON.stringify(newValues.sort()) !== JSON.stringify(values.sort())) {
        this.getUIElement(section_id).setValue(newValues);
      }

      notifications.forEach((notification) =>
        ui.addNotification(null, notification),
      );
      lastValues = newValues;
    } catch (e) {
      console.error("Error in onchange handler:", e);
    } finally {
      isProcessing = false;
    }
  };

  o = modalOption(
    form.ListValue,
    "user_domain_list_type",
    _("User Domain List Type"),
    _("Select the list type for adding custom domains"),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = modalOption(
    form.DynamicList,
    "user_domains",
    _("User Domains"),
    _(
      "Enter domain names without protocols, e.g. example.com or sub.example.com",
    ),
  );
  o.placeholder = "Список доменов";
  o.depends("user_domain_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateDomain(value, true);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.TextValue,
    "user_domains_text",
    _("User Domains List"),
    _(
      "Enter domain names separated by commas, spaces, or newlines. You can add comments using //",
    ),
  );
  o.placeholder =
    "example.com, sub.example.com\n// Социальные сети\ndomain.com test.com // свои домены";
  o.depends("user_domain_list_type", "text");
  o.rows = 8;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const domains = main.parseValueList(value);

    if (!domains.length) {
      return _(
        "At least one valid domain must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(domains, (row) =>
      main.validateDomain(row, true),
    );

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  o = modalOption(
    form.ListValue,
    "user_subnet_list_type",
    _("User Subnet List Type"),
    _("Select the list type for adding custom subnets"),
  );
  o.value("disabled", _("Disabled"));
  o.value("dynamic", _("Dynamic List"));
  o.value("text", _("Text List"));
  o.default = "disabled";
  o.rmempty = false;

  o = modalOption(
    form.DynamicList,
    "user_subnets",
    _("User Subnets"),
    _(
      "Enter subnets in CIDR notation (e.g. 103.21.244.0/22) or single IP addresses",
    ),
  );
  o.placeholder = "IP-адрес или подсеть";
  o.depends("user_subnet_list_type", "dynamic");
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.TextValue,
    "user_subnets_text",
    _("User Subnets List"),
    _(
      "Enter subnets in CIDR notation or single IP addresses, separated by commas, spaces, or newlines. " +
        "You can add comments using //",
    ),
  );
  o.placeholder =
    "103.21.244.0/22\n// DNS Google\n8.8.8.8\n1.1.1.1/32, 9.9.9.9 // Cloudflare и Quad9";
  o.depends("user_subnet_list_type", "text");
  o.rows = 10;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const subnets = main.parseValueList(value);

    if (!subnets.length) {
      return _(
        "At least one valid subnet or IP must be specified. Comments-only content is not allowed.",
      );
    }

    const { valid, results } = main.bulkValidate(subnets, main.validateSubnet);

    if (!valid) {
      const errors = results
        .filter((validation) => !validation.valid) // Leave only failed validations
        .map((validation) => `${validation.value}: ${validation.message}`); // Collect validation errors

      return [_("Validation errors:"), ...errors].join("\n");
    }

    return true;
  };

  o = modalOption(
    form.DynamicList,
    "local_domain_lists",
    _("Local Domain Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "local_subnet_lists",
    _("Local Subnet Lists"),
    _("Specify the path to the list file located on the router filesystem"),
  );
  o.placeholder = "/path/file.lst";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validatePath(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "remote_domain_lists",
    _("Remote Domain Lists"),
    _("Specify remote URLs to download and use domain lists"),
  );
  o.placeholder = "https://example.com/domains.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "remote_subnet_lists",
    _("Remote Subnet Lists"),
    _("Specify remote URLs to download and use subnet lists"),
  );
  o.placeholder = "https://example.com/subnets.srs";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateUrl(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.DynamicList,
    "fully_routed_ips",
    _("Fully Routed IPs"),
    _(
      "Specify local IP addresses or subnets whose traffic will always be routed through the configured route",
    ),
  );
  o.placeholder = "192.168.1.2 или 192.168.1.0/24";
  o.rmempty = true;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = modalOption(
    form.Flag,
    "mixed_proxy_enabled",
    _("Enable Mixed Proxy"),
    _(
      "Enable the mixed proxy, allowing this section to route traffic through both HTTP and SOCKS proxies",
    ),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");

  o = modalOption(
    form.Value,
    "mixed_proxy_port",
    _("Mixed Proxy Port"),
    _(
      "Specify the port number on which the mixed proxy will run for this section. " +
        "Make sure the selected port is not used by another service",
    ),
  );
  o.rmempty = false;
  o.depends("mixed_proxy_enabled", "1");

  o = modalOption(
    form.Flag,
    "resolve_real_ip_for_routing",
    _("Resolve real IP for routing"),
    _("Enable DNS resolve to get real IP when routing"),
  );
  o.default = "0";
  o.rmempty = false;
  o.depends("connection_type", "proxy");
  o.depends("connection_type", "vpn");
}

const EntryPoint = {
  createSectionContent,
};

return baseclass.extend(EntryPoint);
