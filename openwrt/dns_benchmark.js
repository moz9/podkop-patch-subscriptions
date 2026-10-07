"use strict";
"require baseclass";
"require fs";
"require ui";
"require uci";

// Workflow reference: ZeroBlock 0.8.5-r44 DNS benchmark. This adapter uses
// Podkop's isolated worker measures servers and route-aware DNS pairs.
const COMMAND = "/usr/bin/podkop-dns-benchmark";
const SUPPORTED_PROTOCOLS = ["udp", "tcp", "doh", "dot"];
const ERRORS = {
  busy: "Podkop ещё применяет настройки или выполняет другую операцию. Дождитесь завершения и повторите проверку.",
  runtime_busy: "Сейчас выполняется другая операция Podkop. Дождитесь её завершения.",
  pair_not_verified: "Сначала проверьте выбранную DNS-пару. Применение доступно только после успешной проверки.",
  verification_expired: "Результат проверки устарел. Проверьте выбранную пару ещё раз.",
  configuration_changed: "Настройки Podkop изменились после проверки. Проверьте пару заново.",
  worker_stopped: "Процесс проверки остановился. Предыдущие DNS не изменены; запустите проверку снова.",
  cancelled: "Проверка отменена. Настройки DNS не изменены.",
  invalid_pair: "Выбранная DNS-пара недопустима. Выберите рабочие серверы из результатов проверки.",
  invalid_protocol: "Этот протокол DNS пока не поддерживается Podkop PE.",
  no_candidates: "Нет DNS-кандидатов. Проверьте выбранные серверы в настройках.",
  no_working_candidates: "Не найдено рабочей DNS-пары. Посмотрите результаты и причины отказов.",
  process_start_failed: "Не удалось запустить отдельный процесс проверки DNS.",
  config_error: "Не удалось подготовить конфигурацию для проверки DNS.",
  pair_test_failed: "Выбранная пара не прошла проверку DNS и сервисов. Текущие настройки сохранены.",
  apply_failed: "Не удалось применить DNS-пару. Проверьте состояние Podkop и повторите проверку.",
  unsaved_changes: "Сначала сохраните и примените изменения Podkop либо сбросьте их. Затем запускайте проверку DNS.",
  request_failed: "Не удалось получить ответ от процесса проверки DNS. Повторите запрос.",
  stale_proof: "Подтверждение выбранной пары устарело или настройки изменились. Проверьте пару ещё раз.",
  dns_query_failed: "Не все обязательные DNS-запросы получили корректный ответ.",
  nxdomain_check_failed: "DNS подменяет ответ для несуществующего домена. Этот вариант применять нельзя.",
  child_failed: "Не удалось проверить сервер через отдельный DNS-процесс.",
  bootstrap_unavailable: "Bootstrap DNS не отвечает. Выберите другой сервер и повторите проверку.",
  apply_failed_rolled_back: "Новые DNS не прошли проверку после применения. Предыдущие DNS восстановлены.",
  rollback_failed: "Не удалось подтвердить восстановление DNS. Проверьте диагностику и журнал Podkop.",
  apply_interrupted_rolled_back: "Применение было прервано. Предыдущие DNS восстановлены и проверены; повторите проверку пары перед новой попыткой.",
  rollback_interrupted_rolled_back: "Операция была прервана. Восстановление предыдущих DNS завершено и проверено.",
  backup_failed: "Не удалось сохранить предыдущие DNS. Применение отменено.",
  service_transport_failed: "DNS отвечает, но HTTPS-проверка сервиса через Podkop не прошла. Проверьте прокси и маршруты в диагностике.",
  measurement_timeout: "Проверка превысила лимит времени. Выберите меньше DNS-кандидатов и повторите её.",
  unsupported_engine_protocol: "Установленный движок не поддерживает этот DNS-протокол. Доступны UDP, TCP, DoH и DoT.",
  measured_candidates_required: "Сначала выполните режим «Серверы по отдельности». Пары составляются из прошедших его кандидатов.",
  too_many_pairs: "Получилось больше 24 пар. Уменьшите набор DNS-кандидатов в настройках и повторите первый режим.",
  runtime_selection_unavailable: "Не удалось прочитать текущий выбор прокси Podkop. Проверка не будет подменять его другим узлом.",
  active_selection_unavailable: "Не удалось прочитать текущий выбор прокси Podkop. Проверка не будет подменять его другим узлом.",
  unsupported_client_routing: "Маршруты зависят от IP клиента или других параметров исходного подключения. Этот тест не может достоверно воспроизвести их с роутера; рабочие DNS не изменены.",
  unsupported_ruleset_routing: "В конфигурации есть пользовательский внешний или локальный список правил, содержимое которого этот тест не проверяет. Режим пар поддерживает встроенные списки сообщества Podkop и проверенные inline-правила; рабочие DNS не изменены.",
  rules_cache_unavailable: "Не удалось скопировать текущий кеш списков маршрутизации для отдельного процесса. Рабочий Podkop не изменён.",
  netstat_unavailable: "На роутере нет netstat: нельзя безопасно проверить занятость тестовых портов. Измерения не запущены.",
  bootstrap_query_failed: "Bootstrap DNS не ответил на все обязательные запросы. Выберите другой кандидат.",
  invalid_endpoint: "Некорректный DNS-адрес или порт. Проверьте выбранного кандидата.",
  listener_collision: "Локальный порт проверки занят. Дождитесь завершения другой проверки.",
  child_config_invalid: "Движок отклонил конфигурацию отдельного процесса проверки. Рабочий Podkop не изменён.",
  child_start_failed: "Не удалось запустить отдельный процесс проверки. Рабочий Podkop не остановлен.",
  child_dns_unavailable: "Отдельный DNS-процесс не ответил. Рабочие DNS не изменены.",
  invalid_bootstrap_protocol: "Протокол bootstrap DNS не поддерживается. Доступны UDP, TCP, DoH и DoT.",
  stale_candidate: "Кандидат отсутствует в текущем каталоге. Повторите первый режим проверки.",
  runtime_clone_unsupported: "Текущую конфигурацию нельзя безопасно запустить в отдельном процессе. Рабочие настройки не изменены.",
  insufficient_memory: "Недостаточно свободной памяти для отдельного процесса. Рабочий Podkop не остановлен.",
  runtime_cache_unavailable: "Не удалось безопасно скопировать текущие списки маршрутизации. Рабочий Podkop не изменён.",
  runtime_config_unavailable: "Не удалось прочитать рабочую конфигурацию Podkop. Сначала проверьте состояние сервиса.",
};

function errorMessage(value) {
  const code = typeof value === "string" ? value : value?.error || value?.message;
  return ERRORS[code] || "Проверка DNS завершилась с ошибкой. Текущие настройки не изменены.";
}

function normalizeReport(value) {
  function rows(values, bootstrap) {
    if (!Array.isArray(values) || values.length > 256) throw new Error("Некорректный отчёт DNS.");
    return values.map(row => {
      const server = String(bootstrap ? row.server : row.dnsServer).trim();
      const successes = Number(row.successCount), total = Number(row.totalQueries);
      const average = row.averageMs == null ? null : Number(row.averageMs);
      if (!server || server === "undefined" || !SUPPORTED_PROTOCOLS.includes(row.protocol || (bootstrap ? "udp" : "")) ||
          !Number.isInteger(successes) || !Number.isInteger(total) || successes < 0 || total < successes ||
          (successes > 0 && (average == null || !Number.isFinite(average) || average < 0))) {
        throw new Error("Некорректные результаты измерения DNS.");
      }
      return {...row, protocol: row.protocol || "udp", successCount: successes, totalQueries: total, averageMs: successes ? average : null};
    });
  }
  const pairs=value.pairResults || [];
  if (!Array.isArray(pairs) || pairs.length>24) throw new Error("Некорректный отчёт пар DNS.");
  for (const pair of pairs) {
    if (!SUPPORTED_PROTOCOLS.includes(pair.protocol) || !SUPPORTED_PROTOCOLS.includes(pair.bootstrapProtocol || "udp") ||
        !pair.id || !pair.dnsServer || !pair.bootstrapDnsServer || typeof pair.success!=="boolean") throw new Error("Некорректная DNS-пара в отчёте.");
    if (pair.success && (!Number.isInteger(pair.stats?.successCount) || !Number.isInteger(pair.stats?.totalQueries) ||
        pair.stats.successCount<=0 || pair.stats.totalQueries<pair.stats.successCount ||
        !Number.isFinite(pair.stats.averageMs) || pair.stats.averageMs<0)) throw new Error("Некорректные измерения DNS-пары.");
  }
  return {results: rows(value.results, false), bootstrapResults: rows(value.bootstrapResults, true), pairResults: pairs};
}

function pairKey(pair) {
  return [pair.protocol, pair.id, pair.dnsServer, pair.bootstrapDnsServer, pair.bootstrapProtocol || "udp"].map(value => String(value || "")).join("\n");
}

function pairMatches(pair, result) {
  return result?.success === true && pairKey(pair) === pairKey(result);
}

async function request(args) {
  const response = await fs.exec(COMMAND, args);
  let result;
  try { result = JSON.parse(response.stdout || "{}"); } catch (_) { throw new Error(ERRORS.request_failed); }
  if (result.success === false) throw new Error(errorMessage(result));
  if (response.code !== 0) throw new Error(ERRORS.request_failed);
  return result;
}

function ensureStyle() {
  if (document.getElementById("pdk-dns-benchmark-style")) return;
  const style = document.createElement("style"); style.id = "pdk-dns-benchmark-style";
  style.textContent = `
    .pdk-dns-benchmark {width:100%;min-width:0;box-sizing:border-box;container-type:inline-size;font-size:13px}
    .pdk-dns-benchmark__toolbar,.pdk-dns-benchmark__footer {display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:12px 0}
    .pdk-dns-benchmark__pair {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}
    .pdk-dns-benchmark__tabs {display:flex;flex-wrap:wrap;gap:6px;margin:10px 0}
    .pdk-dns-benchmark__tabs .btn[aria-pressed="false"] {background:transparent!important;color:inherit!important}
    .pdk-dns-benchmark__tabs .btn[aria-pressed="true"] {background:var(--primary-color,#568fff);color:#fff}
    .pdk-dns-benchmark [hidden] {display:none!important}
    .pdk-dns-benchmark__scroll {overflow:auto;max-height:min(320px,40vh)}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll table {display:table!important;width:100%;min-width:560px;table-layout:auto}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll thead {display:table-header-group!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tbody {display:table-row-group!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tr {display:table-row!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll th,#modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td {display:table-cell!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td::before {display:none!important}
    .pdk-dns-benchmark th,.pdk-dns-benchmark td {padding:6px 8px;word-break:normal;overflow-wrap:normal;white-space:nowrap;font-size:13px}
    .pdk-dns-benchmark td:first-child {min-width:12em;white-space:normal}
    .pdk-dns-benchmark td:first-child small {display:block;overflow-wrap:anywhere}
    .pdk-dns-benchmark td:last-child {width:28%;white-space:normal}
    .pdk-dns-benchmark summary {white-space:nowrap;cursor:pointer}
    .pdk-dns-benchmark details p {margin:6px 0;line-height:1.4;white-space:normal}
    .pdk-dns-benchmark progress {max-width:140px}
    .pdk-dns-benchmark select {display:block;width:100%;max-width:100%;margin:6px 0}
    .pdk-dns-benchmark__error {color:var(--error-color,#ff5555);overflow-wrap:anywhere}
    .pdk-dns-benchmark__notice {color:var(--text-color-secondary,#94a3b8);margin:8px 0}
    @container(max-width:560px) {.pdk-dns-benchmark__pair{grid-template-columns:1fr}}
    @media(max-width:600px) {.pdk-dns-benchmark__pair{grid-template-columns:1fr}}
  `;
  document.head.appendChild(style);
}

function openBenchmark(map) {
  ensureStyle();
  const state = {open: true, running: false, pending: false, needsReload: false, action: "", report: null, verified: "", timer: null, backup: false, activeTable: 0, mode: "individual"};
  const message = E("div", {"aria-live": "polite"}, "Готов к проверке");
  const error = E("div", {class: "pdk-dns-benchmark__error", role: "alert"});
  const progress = E("progress", {max: 100, value: 0});
  const count = E("span", {});
  const mainSelect = E("select", {"aria-label": "Основной DNS"});
  const bootstrapSelect = E("select", {"aria-label": "Bootstrap DNS"});
  const pairStatus = E("div", {"aria-live": "polite"});
  const resultTables = E("div", {class: "pdk-dns-benchmark__tables"});
  const matrixTables = E("div", {class: "pdk-dns-benchmark__tables"});
  const matrixNotice = E("div", {class: "pdk-dns-benchmark__notice"});
  let start, startPairs, test, apply, cancel, rollback, close;

  function pair() {
    const row = state.report?.results.find(r => r.id + ":" + r.protocol + ":" + r.dnsServer === mainSelect.value);
    const bootstrap=state.report?.bootstrapResults.find(r=>bootstrapValue(r)===bootstrapSelect.value);
    return row && bootstrap ? {protocol: row.protocol, id: row.id, dnsServer: row.dnsServer, bootstrapDnsServer: bootstrap.server, bootstrapProtocol: bootstrap.protocol || "udp"} : null;
  }
  function bootstrapValue(row) { return (row.protocol || "udp")+":"+row.server; }
  function plannedPairs() { return (state.report?.results.filter(r=>r.reliable && r.primaryEligible!==false).length || 0)*(state.report?.bootstrapResults.filter(r=>r.reliable).length || 0); }
  function actions() {
    const busy = state.running || state.pending || state.needsReload;
    start.disabled = busy; test.disabled = busy || !pair() || !bootstrapSelect.value;
    startPairs.disabled = busy || plannedPairs()===0 || plannedPairs()>24;
    modeTabs.forEach(tab=>{tab.disabled=busy;});
    apply.disabled = busy || !pair() || state.verified !== pairKey(pair());
    cancel.disabled = !state.running || ["apply", "rollback"].includes(state.action);
    rollback.disabled = busy || !state.backup;
    close.disabled = state.needsReload || state.pending || state.running && ["apply", "rollback"].includes(state.action);
  }
  function resetVerification() { state.verified = ""; pairStatus.textContent = "Проверьте выбранную пару перед применением."; actions(); }
  mainSelect.addEventListener("change", resetVerification);
  bootstrapSelect.addEventListener("change", resetVerification);
  function renderResults(raw) {
    state.report = normalizeReport(raw);
    const groups=[["Основной DNS",state.report.results,false],["Bootstrap DNS",state.report.bootstrapResults,true]];
    const panels=groups.map(([title,rows,bootstrap]) => E("section",{"aria-label":title},[
      E("div",{class:"pdk-dns-benchmark__scroll",tabindex:0,"aria-label":title+": результаты"},E("table",{},[
        E("thead",{},E("tr",{},["Сервер","Протокол","Ответы","Среднее","Состояние"].map(text=>E("th",{},text)))),
        E("tbody",{},rows.map(row=>E("tr",{},[
          E("td",{},[E("strong",{},String(row.provider || "DNS")),E("small",{},String(bootstrap?row.server:row.dnsServer))]),
          E("td",{},row.protocol.toUpperCase()),
          E("td",{},row.successCount+" / "+row.totalQueries),
          E("td",{},row.averageMs == null ? "—" : row.averageMs.toFixed(1)+" мс"),
          E("td",{},row.reliable ? "Работает" : E("details",{},[
            E("summary",{},row.totalQueries ? "Есть ошибки" : "Недоступен"),
            E("p",{},row.error ? errorMessage(row.error) : "Проверка не пройдена"),
          ])),
        ]))),
      ])),
    ]));
    const tabs=groups.map(([title],index)=>E("button",{class:"btn",type:"button",click:()=>showTable(index)},title));
    function showTable(index) {
      state.activeTable=index;
      panels.forEach((panel,i)=>{panel.hidden=i!==index;tabs[i].setAttribute("aria-pressed",String(i===index));});
    }
    showTable(state.activeTable);
    resultTables.replaceChildren(E("div",{class:"pdk-dns-benchmark__tabs","aria-label":"Результаты DNS"},tabs),...panels);
    const previousMain=mainSelect.value, previousBootstrap=bootstrapSelect.value;
    const mains=state.report.results.filter(row=>row.reliable && row.primaryEligible !== false);
    const bootstraps=state.report.bootstrapResults.filter(row=>row.reliable);
    mainSelect.replaceChildren(...mains.map(row=>E("option",{value:row.id+":"+row.protocol+":"+row.dnsServer},row.protocol.toUpperCase()+" · "+row.dnsServer)));
    bootstrapSelect.replaceChildren(...bootstraps.map(row=>E("option",{value:bootstrapValue(row)},row.protocol.toUpperCase()+" · "+row.server+" · "+row.provider)));
    mainSelect.value=mains.some(row=>row.id+":"+row.protocol+":"+row.dnsServer===previousMain)?previousMain:mains.length?mains[0].id+":"+mains[0].protocol+":"+mains[0].dnsServer:"";
    bootstrapSelect.value=bootstraps.some(row=>bootstrapValue(row)===previousBootstrap)?previousBootstrap:bootstraps.length?bootstrapValue(bootstraps[0]):"";
    matrixNotice.textContent=plannedPairs() ? `Рабочих сочетаний: ${plannedPairs()}. Проверяются все сочетания; лимит — 24 пары. `+(plannedPairs()>24?ERRORS.too_many_pairs:"Измерения не меняют рабочий DNS.") : ERRORS.measured_candidates_required;
    matrixTables.replaceChildren(E("div",{class:"pdk-dns-benchmark__scroll",tabindex:0,"aria-label":"Результаты DNS-пар"},E("table",{},[
      E("thead",{},E("tr",{},["Основной DNS","Bootstrap DNS","Ответы DNS","Среднее DNS","Через Podkop",""].map(label=>E("th",{},label)))),
      E("tbody",{},state.report.pairResults.map(row=>E("tr",{},[
        E("td",{},[row.protocol.toUpperCase(),E("small",{},row.dnsServer)]),
        E("td",{},[(row.bootstrapProtocol || "udp").toUpperCase(),E("small",{},row.bootstrapDnsServer)]),
        E("td",{},row.stats ? `${row.stats.successCount} / ${row.stats.totalQueries}` : "—"),
        E("td",{},Number.isFinite(row.stats?.averageMs)?row.stats.averageMs.toFixed(1)+" мс":"—"),
        E("td",{},row.success ? "DNS + HTTPS работают" : E("details",{},[E("summary",{},"Не прошла"),E("p",{},errorMessage(row.error))])),
        E("td",{},row.success ? E("button",{type:"button",class:"btn",click:()=>{
          mainSelect.value=row.id+":"+row.protocol+":"+row.dnsServer;
          bootstrapSelect.value=(row.bootstrapProtocol || "udp")+":"+row.bootstrapDnsServer;
          resetVerification();pairStatus.textContent="Пара выбрана из результатов. Проверьте её ещё раз перед применением.";
        }},"Выбрать") : "—"),
      ]))),
    ])));
  }
  function stopPoll() { if (state.timer != null) window.clearTimeout(state.timer); state.timer=null; }
  async function refresh() {
    stopPoll();
    try {
      const status=await request(["status"]); if (!state.open) return;
      const reloadAfterCompletion=state.running && ["apply","rollback"].includes(state.action);
      if (!["idle","running","done","error","cancelled"].includes(status.state)) throw new Error(ERRORS.request_failed);
      state.running=status.state === "running"; state.action=status.action || ""; state.backup=!!status.backupAvailable;
      progress.value=Math.min(100,Math.max(0,Number(status.progress)||0));
      count.textContent=(status.action==="pairs" && status.total ? `Пары: ${status.completed || 0} / ${status.total} · ` : "")+(status.queryTotal ? `Запросы: ${status.queryCompleted || 0} / ${status.queryTotal}` : status.total && status.action!=="pairs" ? `${status.completed || 0} / ${status.total}` : "");
      if (Array.isArray(status.results) && Array.isArray(status.bootstrapResults) && status.state !== "running") renderResults(status);
      if (state.running) {
        message.textContent=state.action === "pairs" ? "Проверяем пары через текущие маршруты Podkop…" : state.action === "pair_test" ? "Проверяем выбранную пару и доступность сервисов…" : state.action === "apply" ? "Применяем DNS и проверяем работу Podkop…" : state.action === "rollback" ? "Восстанавливаем предыдущие DNS…" : "Измеряем DNS-кандидатов…";
        state.timer=window.setTimeout(refresh,1000);
      } else if (status.state === "error") {
        error.textContent=errorMessage(status);
        const transport=status.pairResult?.transportError;
        if (transport?.url) error.textContent += ` (${String(transport.url).replace(/^https:\/\//, "").split("/")[0]} · HTTP ${transport.httpStatus || "нет ответа"})`;
        message.textContent="Операция не выполнена"; state.verified="";
      }
      else if (status.state === "cancelled") { message.textContent=ERRORS.cancelled; state.verified=""; }
      else if (status.action === "pair_test" && status.state === "done") {
        const success=pair() && pairMatches(pair(),status.pairResult);
        state.verified=success?pairKey(pair()):"";
        pairStatus.textContent=success?"Пара прошла проверку DNS и сервисов. Можно применить.":ERRORS.pair_test_failed;
        message.textContent="Проверка пары завершена";
      } else if (["apply","rollback"].includes(status.action) && status.state === "done") {
        state.verified=""; message.textContent=status.action === "apply" ? "DNS-пара применена" : "Предыдущие DNS восстановлены";
        if (!reloadAfterCompletion) { actions(); return; }
        state.needsReload=true;
        uci.unload("podkop"); await uci.load("podkop");
        // Server-side apply changed UCI. Reload before allowing LuCI to save its stale form.
        start.disabled=true; test.disabled=true; apply.disabled=true; rollback.disabled=true;
        message.textContent += ". Обновите страницу, чтобы загрузить новые настройки.";
        window.location.reload();
        return;
      } else { message.textContent=status.action==="pairs" ? "Проверка пар завершена. Выберите рабочую пару." : state.report?"Измерения завершены. Выберите и проверьте пару.":"Готов к проверке"; }
    } catch (failure) { error.textContent=failure.message || ERRORS.request_failed; if(state.running && state.open)state.timer=window.setTimeout(refresh,1500); }
    if (state.open) actions();
  }
  async function hasChanges() {
    if (map?.root?.querySelector('[data-changed="true"]')) return true;
    const changes=await uci.changes();
    return !!changes?.podkop?.length;
  }
  async function operate(command, args=[]) {
    if (state.pending || state.running || state.needsReload) return;
    state.pending=true; actions(); error.textContent="";
    try {
      if(await hasChanges())throw new Error(ERRORS.unsaved_changes);
      state.verified=""; pairStatus.textContent="";
      const accepted=await request([command,...args]);
      if (accepted.success !== true) throw new Error(ERRORS.request_failed);
      state.running=true; state.action=command.replace(/_start$/,"");
      await refresh();
    } catch(failure) { error.textContent=failure.message || ERRORS.request_failed; }
    finally {state.pending=false;actions();}
  }
  function makeButton(label,fn,kind="cbi-button-action") { return E("button",{type:"button",class:"cbi-button "+kind,click:event=>{event.preventDefault();return fn();}},label); }
  start=makeButton("Проверить DNS",()=>operate("benchmark_start"));
  startPairs=makeButton("Проверить пары",()=>operate("pairs_start"));
  function pairArgs(selected) { return [selected.protocol,selected.id,selected.dnsServer,selected.bootstrapDnsServer,selected.bootstrapProtocol]; }
  test=makeButton("Проверить пару",()=>{const selected=pair();return selected && operate("pair_test_start",pairArgs(selected));});
  apply=makeButton("Применить пару",()=>{const selected=pair();return selected && state.verified===pairKey(selected) && operate("apply_start",pairArgs(selected));},"cbi-button-apply");
  rollback=makeButton("Откатить DNS",()=>operate("rollback_start"),"cbi-button-reset");
  cancel=makeButton("Отменить проверку",async()=>{if(["apply","rollback"].includes(state.action))return;try{await request(["cancel"]);await refresh();}catch(failure){error.textContent=failure.message;}},"cbi-button-reset");
  close=makeButton("Закрыть",()=>{if(close.disabled)return;state.open=false;stopPoll();ui.hideModal();if(state.running)request(["cancel"]).catch(()=>{});},"cbi-button-reset");
  const modeTabs=["1. Серверы по отдельности","2. Пары через Podkop"].map((label,index)=>makeButton(label,()=>showMode(index===0?"individual":"pairs")));
  function showMode(mode) {
    state.mode=mode; const matrix=mode==="pairs";
    resultTables.hidden=matrix;matrixTables.hidden=!matrix;matrixNotice.hidden=!matrix;start.hidden=matrix;startPairs.hidden=!matrix;
    modeTabs.forEach((tab,index)=>tab.setAttribute("aria-pressed",String((index===1)===matrix)));
  }
  showMode("individual");
  const content=E("div",{class:"pdk-dns-benchmark"},[
    E("div",{class:"pdk-dns-benchmark__notice"},"Два режима: отдельные серверы и целые пары через текущую конфигурацию Podkop. Сначала измерьте серверы, затем сравните рабочие сочетания. Закрытие окна отменяет проверку."),
    E("div",{class:"pdk-dns-benchmark__tabs","aria-label":"Режим проверки DNS"},modeTabs),
    E("div",{class:"pdk-dns-benchmark__toolbar"},[start,startPairs,message,progress,count,cancel]),error,resultTables,matrixNotice,matrixTables,
    E("div",{class:"pdk-dns-benchmark__pair"},[
      E("label",{},["Основной DNS",mainSelect]),E("label",{},["Bootstrap DNS",bootstrapSelect]),
    ]),pairStatus,E("div",{class:"pdk-dns-benchmark__footer"},[test,apply,rollback,close]),
    E("div",{class:"pdk-dns-benchmark__notice"},"Во втором режиме и при проверке пары DNS и HTTPS используют тестируемую пару, текущие маршруты и выбранные прокси Podkop в отдельном процессе. Применение — только по кнопке, с повторной проверкой и откатом при отказе. Это не заменяет проверку приложения на телефоне."),
  ]);
  actions();ui.showModal("Бенчмарк DNS",[content]);refresh();
}

function renderOpenButton(map) {
  return E("button",{type:"button",class:"cbi-button cbi-button-action",click:event=>{event.preventDefault();openBenchmark(map);}},"Открыть бенчмарк DNS");
}

return baseclass.extend({renderOpenButton,normalizeReport,pairMatches,errorMessage});
