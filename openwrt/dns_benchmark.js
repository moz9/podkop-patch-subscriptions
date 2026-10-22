"use strict";
"require baseclass";
"require fs";
"require ui";
"require uci";

// Workflow reference: ZeroBlock 0.8.5-r44 DNS benchmark. This adapter uses
// Podkop's isolated worker measures servers and route-aware DNS pairs.
const COMMAND = "/usr/bin/podkop-dns-benchmark";
const SUPPORTED_PROTOCOLS = ["udp", "tcp", "doh", "dot"];
const RECOMMENDATION_ACTIONS = ['recommend','recommend_full','recommend_verified','recommend_reserve'];
const ERRORS = {
  stale_reserve_proof: "Резерв не подтверждён текущей полной проверкой. Подберите резервную пару заново.",
  reserve_pending_conflict: "В ожидающих настройках изменены DNS или авторезерв. Сохраните или отмените именно эти изменения перед сохранением резерва.",
  reserve_recheck_required: "После обновления повторите подбор резерва. Предыдущая проверка не подтверждает отдельное сохранение.",
  reserve_commit_failed: "Не удалось записать резерв в конфигурацию. Проверьте сохранённый резерв и повторите запрос.",
  reserve_readback_failed: "Не удалось подтвердить записанный резерв. Состояние сохранения неизвестно; проверьте сохранённый резерв.",
  reserve_is_active: "Резерв сейчас используется как рабочий DNS. Его отдельная замена заблокирована.",
  unsafe_reserve_config: "Конфигурация не позволяет безопасно записать только резервные поля. Сохранение остановлено.",
  reserve_pending_unavailable: "Не удалось проверить ожидающие изменения UCI. Резерв не сохранён.",
  reserve_delta_invalid: "Изменения резерва вышли за допустимые поля. Сохранение остановлено.",
  unsupported_reserve_config: "Формат конфигурации не поддерживает безопасное отдельное сохранение резерва.",
  current_provider_unknown: "Провайдер текущего DNS неизвестен. Подбор независимого резерва остановлен; DNS не изменены.",
  independent_reserve_unavailable: "В выбранном каталоге нет независимой резервной пары с другими провайдерами. DNS не изменены.",
  pending_recovery_required: "Предыдущее восстановление DNS не завершено. Новое применение заблокировано, чтобы сохранить резервную копию; сначала выполните откат.",
  preparation_failed: "Не удалось безопасно подготовить DNS-конфигурацию. Применение не начато; проверьте состояние Podkop и резервных данных.",
  runtime_unavailable: "Не удалось подтвердить работу текущих DNS-процессов. Новая DNS-пара не применена.",
  runtime_changed: "Рабочая конфигурация изменилась. Операция остановлена, чтобы не перезаписать новые настройки.",
  incomplete_backup: "Резервная копия DNS неполна. Автоматическое восстановление остановлено; требуется проверка сохранённых данных.",
  insufficient_backup_space: "Для безопасной резервной копии недостаточно места. DNS не изменены.",
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
  stale_proof: "Выбранная пара не подтверждена текущим результатом: настройки изменились, проверка отменена или её заменил другой прогон. Проверьте выбранную пару ещё раз.",
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
  measurement_timeout: "Время проверки истекло. Подбор не завершён, лучшая пара не определена. Рабочие DNS не изменены.",
  unsupported_engine_protocol: "Установленный движок не поддерживает этот DNS-протокол. Доступны UDP, TCP, DoH и DoT.",
  measured_candidates_required: "Сначала выполните режим «Серверы по отдельности». Пары составляются из прошедших его кандидатов.",
  too_many_pairs: "Набор пар превышает безопасный размер отчёта. Рабочие DNS не изменены.",
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
  insufficient_memory: "Недостаточно свободной памяти для безопасной проверки. Рабочие подключения не изменены.",
  memory_policy_unreadable: "Не удалось прочитать правила защиты памяти. Проверка не запущена, рабочие подключения не изменены.",
  memory_status_unavailable: "Не удалось определить свободную память. Проверка остановлена, рабочие подключения не изменены.",
  diagnostic_policy_unavailable: "Недоступны правила безопасной проверки. Рабочие подключения не изменены.",
  clock_unavailable: "Не удалось определить время для ограничения проверки. Рабочие подключения не изменены.",
  runtime_cache_unavailable: "Не удалось безопасно скопировать текущие списки маршрутизации. Рабочий Podkop не изменён.",
  runtime_config_unavailable: "Не удалось прочитать рабочую конфигурацию Podkop. Сначала проверьте состояние сервиса.",
  unsupported_section_runtime: "Эту секцию пока нельзя безопасно воспроизвести в отдельном процессе. Рабочие подключения не изменены.",
  section_scope_unverified: "Для одной из секций нет достаточных контрольных адресов. Подбор не выдаёт непроверенную рекомендацию.",
  section_dns_failed: "В тестовой секции есть ошибки DNS. Рабочая секция не изменена.",
  section_transport_failed: "Контрольный сайт не открылся через тестовую секцию. Это может быть связано с DNS, прокси или самим сайтом.",
  memory_pressure: "На роутере осталось мало свободной памяти. Проверка остановлена для защиты рабочих подключений.",
  production_stopped: "Рабочий процесс Podkop остановился или был заменён. Тестовые процессы остановлены; проверьте диагностику.",
  deadline_runner_unavailable: "Недоступна безопасная проверка с ограничением времени. Тест не запущен, рабочий Podkop не изменён.",
  private_oom_unavailable: "Не удалось защитить рабочий Podkop от нехватки памяти. Тест не запущен.",
  no_stable_pair: "Среди проверенных пар нет подтверждённой рабочей. Это не означает, что не работают остальные кандидаты. DNS не изменены.",
  no_fully_verified_pairs: "Ни одна из проверенных пар-финалистов не прошла полную проверку. Причины показаны в результатах; это не означает отказ всего каталога. DNS не изменены.",
  insufficient_working_pairs: "Не удалось подтвердить минимум две рабочие пары. Сравнения недостаточно — лучшая не выбрана. DNS не изменены.",
  stability_comparison_incomplete: "Рабочие пары найдены, но сравнение стабильности не завершено. Лучший вариант не выбран. DNS не изменены.",
  sample_scope_unverified: "Не удалось составить контрольную выборку адресов. Рекомендация не выдана, DNS не изменены.",
  pair_budget_exceeded: "Пара не уложилась в короткую проверку. Это не доказывает, что DNS не работает; доступна полная проверка вручную.",
  dns_apply_helper_unavailable: "Не удалось запустить безопасное применение DNS. Проверьте состояние Podkop и повторите проверку пары перед новой попыткой.",
  dns_apply_result_unknown: "Результат применения DNS неизвестен. Проверьте текущие настройки и состояние Podkop перед следующими действиями.",
  dns_apply_interrupted_unchanged: "Применение было прервано до изменения DNS. Проверьте состояние Podkop и повторите проверку пары.",
};

function errorMessage(value) {
  const lightErrors={
    unsupported_dns_route:"Быстрый тест поддерживает только прямой маршрут DNS. Проверка через прокси требует расширенной диагностики; DNS не изменены.",
    incomplete_measurement:"Измерения не завершены. Подтверждённых двух пар нет; DNS не изменены.",
    independent_reserve_unavailable:"Не удалось подтвердить независимую резервную пару. DNS не изменены."
  };
  const code = typeof value === "string" ? value : value?.error || value?.message;
  return lightErrors[code] || ERRORS[code] || "Операция DNS завершилась с ошибкой. Проверьте текущие настройки и состояние Podkop перед следующими действиями.";
}

function normalizeReport(value) {
  const partialEndpoints=value.state==='running' && value.selectionMode==='two_stage' && value.stage==='endpoints' && ['main','bootstrap'].every(kind=>{
    const coverage=value.endpointCoverage?.[kind];
    return Number.isSafeInteger(coverage?.selected) && coverage.selected>=0 && Number.isSafeInteger(coverage.tested) && coverage.tested>=0 && coverage.tested<=coverage.selected;
  });
  function catalog(values, bootstrap) {
    if (values == null) return null; // Older reports only have measured rows.
    if (!Array.isArray(values) || values.length > 256) throw new Error("Некорректный каталог DNS.");
    return values.map(row => {
      const server = String((bootstrap ? row.server : row.dnsServer || (partialEndpoints ? row.server : '')) || "").trim();
      const protocol = row.protocol || (bootstrap ? "udp" : "");
      if (!server || !SUPPORTED_PROTOCOLS.includes(protocol) || (!bootstrap && !row.id)) throw new Error("Некорректный кандидат DNS.");
      return {...row, protocol, [bootstrap ? 'server' : 'dnsServer']:server};
    });
  }
  function rows(values, bootstrap) {
    if (!Array.isArray(values) || values.length > 256) throw new Error("Некорректный отчёт DNS.");
    return values.map(row => {
      const server = String(bootstrap ? row.server : row.dnsServer || (partialEndpoints ? row.server : undefined)).trim();
      const protocol=row.protocol || (bootstrap ? "udp" : "");
      if ((row.measured===false || partialEndpoints && row.measured==null) && row.successCount==null && row.totalQueries==null && row.averageMs==null) {
        if (!server || server==="undefined" || !SUPPORTED_PROTOCOLS.includes(protocol)) throw new Error("Некорректный кандидат DNS.");
        return {...row, protocol,measured:false,[bootstrap?'server':'dnsServer']:server};
      }
      const successes = Number(row.successCount), total = Number(row.totalQueries);
      const average = row.averageMs == null ? null : Number(row.averageMs);
      if (!server || server === "undefined" || !SUPPORTED_PROTOCOLS.includes(protocol) ||
          !Number.isInteger(successes) || !Number.isInteger(total) || successes < 0 || total < successes ||
          (successes > 0 && (average == null || !Number.isFinite(average) || average < 0))) {
        throw new Error("Некорректные результаты измерения DNS.");
      }
      return {...row, protocol, successCount: successes, totalQueries: total, averageMs: successes ? average : null};
    });
  }
  let pairs=value.pairResults || [];
  if (!Array.isArray(pairs) || pairs.length>65536) throw new Error("Некорректный отчёт пар DNS.");
  const reserve=value.action==='recommend_reserve';
  const verifiedWorkflow=value.action==='recommend_verified' || reserve;
  const preliminaryPairs=pairs;
  const fullResults=verifiedWorkflow ? value.fullVerificationResults || [] : [];
  if(!Array.isArray(fullResults) || fullResults.length>256) throw new Error("Некорректный отчёт полной проверки DNS.");
  if(verifiedWorkflow) for(const result of fullResults) pairs=[...pairs.filter(pair=>pairKey(pair)!==pairKey(result)),result];
  const latestPairResult=value.action==='pair_test' && ['done','error'].includes(value.state) && typeof value.pairResult?.success==='boolean' ? value.pairResult : null;
  const latestPairFailure=latestPairResult?.success===false ? latestPairResult : null;
  if(latestPairResult) pairs=[...pairs.filter(pair=>pairKey(pair)!==pairKey(latestPairResult)),latestPairResult];
  for (const pair of pairs) {
    if (!SUPPORTED_PROTOCOLS.includes(pair.protocol) || !SUPPORTED_PROTOCOLS.includes(pair.bootstrapProtocol || "udp") ||
        !pair.id || !pair.dnsServer || !pair.bootstrapDnsServer || typeof pair.success!=="boolean") throw new Error("Некорректная DNS-пара в отчёте.");
    if (pair.success && (!Number.isInteger(pair.stats?.successCount) || !Number.isInteger(pair.stats?.totalQueries) ||
        pair.stats.successCount<=0 || pair.stats.totalQueries<pair.stats.successCount ||
        !Number.isFinite(pair.stats.averageMs) || pair.stats.averageMs<0)) throw new Error("Некорректные измерения DNS-пары.");
  }
  const sampled=value.measurementProfile==='minute_sample';
  const allSelected=value.selectionMode==='all_selected';
  const staged=value.selectionMode==='two_stage';
  const strict=allSelected || staged;
  const candidatesTotal=Number.isSafeInteger(value.candidatesTotal)&&value.candidatesTotal>=0?value.candidatesTotal:0;
  const pairsTested=Number.isSafeInteger(value.pairsTested)&&value.pairsTested>=0?value.pairsTested:pairs.length;
  const successfulPairs=new Set((verifiedWorkflow?preliminaryPairs:pairs).filter(pair=>pair.success && pair.httpsTested!==false && (strict ? pair.automaticEligible===true && pair.comparisonOnly!==true && pair.rechecked===true && pair.stats?.reliable===true : pair.rechecked!==false)).map(pairKey)).size;
  const recommendedRow=value.recommendation ? pairs.find(pair=>pairKey(pair)===pairKey(value.recommendation)) : null;
  if(reserve) {
    const proof=value.recommendationBootstrapTest, winner=value.recommendation;
    const provider=String(winner?.mainFamily || winner?.provider || ''), bootProvider=String(winner?.bootstrapFamily || winner?.bootstrapProvider || ''), excluded=String(value.excludedProvider || '');
    const independent=provider && bootProvider && excluded && provider!==excluded && bootProvider!==excluded && bootProvider!==String(value.currentBootstrapProvider || '') && provider!==bootProvider;
    if(!independent || proof?.success!==true || proof.protocol!==(winner?.bootstrapProtocol || 'udp') || proof.server!==winner?.bootstrapDnsServer || !Array.isArray(proof.checks) || !proof.checks.length || proof.checks.some(check=>check.success!==true)) value={...value,recommendation:null};
  }
  const fullProof=!verifiedWorkflow || value.state==='done' && value.fullVerificationComplete===true && value.recommendation?.measurementProfile==='full' && value.recommendation.stats?.reliable===true && value.pairResult?.measurementProfile==='full' && value.pairResult.success===true && value.pairResult.rechecked===true && value.pairResult.automaticEligible===true && value.pairResult.stats?.reliable===true && value.pairResult.httpsTested!==false && pairMatches(value.recommendation,value.pairResult) && fullResults.some(row=>row.measurementProfile==='full' && row.success===true && row.stats?.reliable===true && pairMatches(value.recommendation,row));
  const recommendation=fullProof && (!(sampled || staged) || value.comparisonComplete===true && successfulPairs>=2) && (!allSelected || value.exhaustiveSelected===true && candidatesTotal>0 && pairsTested>=candidatesTotal) && value.selectionComplete === true && value.recommendation?.success === true && value.recommendation?.rechecked === true && value.recommendation?.httpsTested!==false &&
    recommendedRow?.success===true && recommendedRow.httpsTested!==false && (!strict || recommendedRow.automaticEligible===true && recommendedRow.comparisonOnly!==true && recommendedRow.stats?.reliable===true && recommendedRow.rechecked===true && value.recommendation.automaticEligible===true && value.recommendation.comparisonOnly!==true) ? value.recommendation : null;
  return {results: rows(value.results, false), bootstrapResults: rows(value.bootstrapResults, true), pairResults: pairs, recommendation,latestPairFailure,
    reportId:typeof value.reportId==='string'?value.reportId:'',
    availableResults:catalog(value.availableResults,false),availableBootstrapResults:catalog(value.availableBootstrapResults,true),
    selectionMode:allSelected?'all_selected':staged?'two_stage':value.selectionMode==='fast'?'fast':'full',searchComplete:value.searchComplete===true,
    endpointCoverage:value.endpointCoverage,stage:typeof value.stage==='string'?value.stage:'',
    reserve,excludedProvider:String(value.excludedProvider || ''),currentPrimaryProvider:String(value.currentPrimaryProvider || ''),currentBootstrapProvider:String(value.currentBootstrapProvider || ''),recommendationBootstrapTest:value.recommendationBootstrapTest,
    verifiedWorkflow,fullVerificationComplete:verifiedWorkflow && fullProof && !!recommendation,
    fullVerificationAttempts:Number.isSafeInteger(value.fullVerificationAttempts)&&value.fullVerificationAttempts>=0?value.fullVerificationAttempts:0,
    fullVerificationResults:fullResults,
    shortlistLimit:Number.isSafeInteger(value.shortlistLimit)&&value.shortlistLimit>0?value.shortlistLimit:8,
    shortlistedPairs:Number.isSafeInteger(value.shortlistedPairs)&&value.shortlistedPairs>=0?value.shortlistedPairs:0,
    httpsTestedPairs:Number.isSafeInteger(value.httpsTestedPairs)&&value.httpsTestedPairs>=0?value.httpsTestedPairs:pairsTested,
    untestedHttpsPairs:Number.isSafeInteger(value.untestedHttpsPairs)&&value.untestedHttpsPairs>=0?value.untestedHttpsPairs:Math.max(0,candidatesTotal-pairsTested),
    comparisonComplete:value.comparisonComplete===true,
    exhaustiveSelected:value.exhaustiveSelected===true,
    measurementProfile:sampled?'minute_sample':value.measurementProfile==='native_endpoints'?'native_endpoints':'full',successfulPairs,
    candidatesTotal,pairsTested,
    parallelism:Number.isSafeInteger(value.parallelism)&&value.parallelism>=1?value.parallelism:0,
    elapsedSeconds:Number.isFinite(value.elapsedSeconds)&&value.elapsedSeconds>=0?Math.round(value.elapsedSeconds):0,
    testedSections:Array.isArray(value.testedSections)?value.testedSections.filter(s=>typeof s==='string'):[]};
}

function pairKey(pair) {
  return [pair.protocol, pair.id, pair.dnsServer, pair.bootstrapDnsServer, pair.bootstrapProtocol || "udp"].map(value => String(value || "")).join("\n");
}

function precheckStateText(row) {
  const passed=row.quickReliable ?? row.reliable;
  if(row.probeScope==='direct_native_dns_ordering_only') return passed ? "DNS отвечает" : "Есть ошибки DNS";
  return passed ? "Короткая проверка: отвечает" : "Короткая проверка: есть ошибки; проверим через секции";
}

function fastSearchText(report) {
  const integer=value=>Number.isSafeInteger(value)&&value>=0?value:0;
  const scope=report.measurementProfile==='minute_sample'?' Экспресс — не полная проверка.':'';
  return `Быстрый подбор: ${integer(report.pairsTested)} из ${integer(report.candidatesTotal)}; не полный перебор.${scope} Время: ${integer(report.elapsedSeconds)} с.`;
}

function selectedSearchText(report) {
  const scope=report.measurementProfile==='minute_sample'?' Экспресс — не полная проверка.':'';
  const parallel=report.parallelism ? ` Параллельно: ${report.parallelism}.` : "";
  return `Все выбранные: ${report.pairsTested} из ${report.candidatesTotal}.${parallel}${scope} Время: ${Number.isSafeInteger(report.elapsedSeconds)&&report.elapsedSeconds>=0?report.elapsedSeconds:0} с.`;
}

function stagedSearchText(report) {
  const integer=value=>Number.isSafeInteger(value)&&value>=0?value:0;
  const coverage=report.endpointCoverage || {};
  return `DNS основных: ${integer(coverage.main?.tested)} / ${integer(coverage.main?.selected)}; bootstrap: ${integer(coverage.bootstrap?.tested)} / ${integer(coverage.bootstrap?.selected)}. Пары: ${integer(report.httpsTestedPairs ?? report.pairsTested)} / ${integer(report.candidatesTotal)}. HTTPS не проверен: ${integer(report.untestedHttpsPairs ?? Math.max(0,integer(report.candidatesTotal)-integer(report.pairsTested)))} — не отказ. Время: ${integer(report.elapsedSeconds)} с.`;
}

function pairMatches(pair, result) {
  return result?.success === true && result.httpsTested!==false && pairKey(pair) === pairKey(result);
}

function pairSummary(row) {
  const untested=row.httpsTested===false;
  if(untested && row.success) return "DNS отвечает; HTTPS не проверен";
  if(!untested && (row.comparisonOnly===true || row.automaticEligible===false)) return "Только для сравнения";
  if(row.rechecked===false && Array.isArray(row.confirmations) && row.confirmations.length) return "Повторная проверка не пройдена";
  if(row.success) return (row.measurementProfile==='minute_sample'?"Экспресс-проверка пройдена":"DNS + TLS/HTTP отвечают")+(row.stats?.retryCount>0?" с повтором":"");
  const suffix=untested?"; HTTPS не проверен":"";
  if(['dns_query_failed','nxdomain_check_failed','bootstrap_query_failed','bootstrap_unavailable','section_dns_failed'].includes(row.error)) return "Ошибки DNS"+suffix;
  if(['service_transport_failed','section_transport_failed'].includes(row.error)) return "Сервис недоступен"+suffix;
  return "Тест не выполнен"+suffix;
}

function queryFailureNodes(value,limit=6,section="") {
  const failures=Array.isArray(value?.failedQueries)?value.failedQueries:Array.isArray(value?.queryErrors)?value.queryErrors:[];
  const seen=new Set();
  return failures.filter(row=>{
    if(!row || typeof row.domain!=="string") return false;
    const key=row.domain+":"+(row.error || row.reason || "");
    if(seen.has(key)) return false;
    seen.add(key); return true;
  }).slice(0,limit).map(row=>{
    const code=String(row.error || row.reason || "").split("|").pop();
    const reason={SERVFAIL:"ошибка сервера",NXDOMAIN:"имя не найдено",REFUSED:"запрос отклонён",TIMEOUT:"таймаут (нет ответа)",NO_RESPONSE:"нет ответа",UNUSABLE_ANSWER:"нет пригодного IP-ответа"}[code] || "ошибка DNS";
    return E("p",{},section ? String(section)+" → "+row.domain+" → "+reason : row.domain+": "+reason);
  });
}

function transportFailureText(transport) {
  const host=String(transport?.url || "").match(/^https?:\/\/(?:[^/\s]*@)?(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::\d+)?(?:[/?#]|$)/i)?.[1] || "контрольный сайт";
  const status=/^[1-5][0-9]{2}$/.test(String(transport?.httpStatus))?transport.httpStatus:"нет ответа";
  const connectionReason={7:"соединение не установлено",28:"время ожидания истекло",35:"сбой TLS-соединения",52:"сервер не прислал ответ",56:"соединение оборвалось",60:"ошибка сертификата"}[transport?.curlExit] || "соединение не установлено";
  const reason={curl_failed:connectionReason,response_too_small:"ответ слишком короткий",unexpected_status:"неожиданный ответ"}[transport?.reason] || "проверка соединения не пройдена";
  return host+" · HTTP "+status+" · "+reason;
}

function endpointContext(pair) {
  if(typeof pair?.primaryEndpointHost!=="string" || !pair.primaryEndpointHost || typeof pair.bootstrapRequiredForPrimary!=="boolean") return "";
  return "Адрес DNS в тесте: "+pair.primaryEndpointHost+". "+(pair.bootstrapRequiredForPrimary?"Bootstrap нужен для его имени.":"Bootstrap не нужен для адреса основного DNS.");
}

function repeatFailureNodes(row) {
  if(row.rechecked!==false || !Array.isArray(row.confirmations)) return [];
  const repeat=row.confirmations.find(result=>result && (result.success!==true || result.stats?.reliable===false));
  if(!repeat) return [];
  const section=Array.isArray(repeat.sectionResults)?repeat.sectionResults.find(result=>result?.success===false):null;
  const domains=queryFailureNodes(repeat.stats,2);
  return [E("p",{},"Неудачный повтор: "+errorMessage(repeat.error || repeat.stats?.error || "pair_test_failed")),
    ...(domains.length?domains:queryFailureNodes(section,2)),
    ...(section?[E("p",{},String(section.section)+": "+errorMessage(section.error))]:[]),
    ...(section?.transportError?[E("p",{},transportFailureText(section.transportError))]:[])];
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
    #modal_overlay .modal:has(.pdk-dns-benchmark) {width:min(80rem,calc(100vw - 2rem))!important;min-width:0!important;max-width:calc(100vw - 2rem)!important;box-sizing:border-box}
    .pdk-dns-benchmark {width:100%;min-width:0;box-sizing:border-box;container-type:inline-size;font-size:13px}
    .pdk-dns-benchmark__toolbar,.pdk-dns-benchmark__footer {display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:12px 0}
    .pdk-dns-benchmark__pair {display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}
    .pdk-dns-benchmark__tabs {display:flex;flex-wrap:wrap;gap:6px;margin:10px 0}
    .pdk-dns-benchmark__tabs .btn[aria-pressed="false"] {background:transparent!important;color:inherit!important}
    .pdk-dns-benchmark__tabs .btn[aria-pressed="true"] {background:var(--primary-color,#568fff);color:#fff}
    .pdk-dns-benchmark [hidden] {display:none!important}
    .pdk-dns-benchmark__scroll {max-width:100%;min-width:0}
    .pdk-dns-benchmark__matrix {margin:12px 0;min-width:0}
    .pdk-dns-benchmark__matrix-scroll {max-height:min(26rem,45vh);overflow-y:auto;overflow-x:hidden;overscroll-behavior:contain;margin-top:8px}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll table {display:table!important;width:100%!important;min-width:0!important;table-layout:fixed}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll thead {display:table-header-group!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tbody {display:table-row-group!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tr {display:table-row!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll th,#modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td {display:table-cell!important}
    #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td::before {display:none!important}
    #modal_overlay .pdk-dns-benchmark th,#modal_overlay .pdk-dns-benchmark td {padding:6px 8px;min-width:0!important;word-break:normal;overflow-wrap:anywhere;white-space:normal!important;font-size:13px;box-sizing:border-box}
    .pdk-dns-benchmark td small {display:block;overflow-wrap:anywhere}
    .pdk-dns-benchmark summary {white-space:normal;overflow-wrap:anywhere;cursor:pointer}
    .pdk-dns-benchmark details p {margin:6px 0;line-height:1.4;white-space:normal}
    .pdk-dns-benchmark progress {max-width:140px}
    .pdk-dns-benchmark select {display:block;width:100%;min-width:0;max-width:100%;margin:6px 0;box-sizing:border-box}
    .pdk-dns-benchmark__pair label,.pdk-dns-benchmark__toolbar>*,.pdk-dns-benchmark__footer>* {min-width:0;max-width:100%;overflow-wrap:anywhere}
    .pdk-dns-benchmark .btn {white-space:normal!important;max-width:100%}
    .pdk-dns-benchmark__error {color:var(--error-color,#ff5555);overflow-wrap:anywhere}
    .pdk-dns-benchmark__notice {color:var(--text-color-secondary,#94a3b8);margin:8px 0}
    @container(max-width:560px) {.pdk-dns-benchmark__pair{grid-template-columns:1fr}}
    @media(max-width:600px) {.pdk-dns-benchmark__pair{grid-template-columns:1fr}}
    @container(max-width:900px) {
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll table,#modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tbody {display:block!important}
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll thead {display:none!important}
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tr {display:grid!important;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 12px;padding:12px 0;margin:0 0 12px;border-bottom:1px solid var(--border-color,#64748b)}
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td {display:block!important;width:auto!important;padding:4px 6px}
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll td::before {display:block!important;content:attr(data-label)!important;position:static!important;width:auto!important;margin:0 0 4px;font-size:11px;font-weight:600;opacity:.75;white-space:normal}
      #modal_overlay .pdk-dns-benchmark td[data-label="Через Podkop"],#modal_overlay .pdk-dns-benchmark td[data-label="Состояние"] {grid-column:1/-1}
    }
    @container(max-width:380px) {
      #modal_overlay .pdk-dns-benchmark .pdk-dns-benchmark__scroll tr {grid-template-columns:minmax(0,1fr)}
    }
  `;
  document.head.appendChild(style);
}

function normalizeLightSelection(value) {
  if(value?.action!=="select" || value.state!=="done" || value.selectionComplete!==true || value.partial!==false ||
     value.scope!=="direct_dns_pair" || !value.reportId) return null;
  const pairs=[value.recommendation,value.secondaryRecommendation];
  if(pairs.some(p=>!p || p.success!==true || !SUPPORTED_PROTOCOLS.includes(p.protocol) ||
      !SUPPORTED_PROTOCOLS.includes(p.bootstrapProtocol) || !p.id || !p.dnsServer || !p.bootstrapDnsServer ||
      !p.mainFamily || !p.bootstrapFamily || p.mainFamily===p.bootstrapFamily)) return null;
  if(new Set(pairs.flatMap(p=>[p.mainFamily,p.bootstrapFamily])).size!==4) return null;
  return {reportId:value.reportId,primary:pairs[0],secondary:pairs[1]};
}

function catalogCandidates(report, catalog, bootstrap) {
  const available=bootstrap?report?.availableBootstrapResults:report?.availableResults;
  const measured=bootstrap?report?.bootstrapResults:report?.results;
  const fallback=bootstrap?catalog?.availableBootstrapResults:catalog?.availableResults;
  const rows=[...(available || measured || []),...(fallback || [])];
  const seen=new Set();
  return rows.filter(row=>{
    const key=(bootstrap?'':row.id+':')+row.protocol+':'+(bootstrap?row.server:row.dnsServer);
    if(seen.has(key)) return false;
    seen.add(key);return true;
  });
}

function openBenchmark(map) {
  ensureStyle();
  const state = {open: true, running: false, pending: false, needsReload: false, action: "", report: null, catalog: null, verified: "", timer: null, backup: false, activeTable: 0, mode: "individual"};
  const message = E("div", {"aria-live": "polite"}, "Готов к проверке");
  const error = E("div", {class: "pdk-dns-benchmark__error", role: "alert"});
  const progress = E("progress", {max: 100, value: 0});
  const count = E("span", {});
  const mainSelect = E("select", {"aria-label": "Основной DNS"});
  const bootstrapSelect = E("select", {"aria-label": "Bootstrap DNS"});
  const pairStatus = E("div", {"aria-live": "polite"});
  const resultTables = E("div", {class: "pdk-dns-benchmark__tables"});
  const matrixBody = E("tbody", {});
  const matrixScroll = E("div", {class:"pdk-dns-benchmark__scroll pdk-dns-benchmark__matrix-scroll",role:"region",tabindex:0,"aria-label":"Результаты DNS-пар"}, E("table", {}, [
    E("thead",{},E("tr",{},["Основной DNS","Bootstrap DNS","Базовый DNS","Среднее DNS","Оценка DNS + HTTPS","Через Podkop",""].map(label=>E("th",{},label)))), matrixBody,
  ]));
  const matrixTables = E("div", {class: "pdk-dns-benchmark__tables"}, matrixScroll);
  const matrixRows = new Map();
  let resultsSnapshot = "", lastRecommendation = "";
  const matrixSummary = E("summary", {}, "Все результаты DNS-пар");
  const matrixDetails = E("details", {class: "pdk-dns-benchmark__matrix", hidden: true}, [matrixSummary, matrixTables]);
  const matrixNotice = E("div", {class: "pdk-dns-benchmark__notice"});
  const recommendationNotice=E("div",{class:"pdk-dns-benchmark__notice","aria-live":"polite"});
  const catalogNotice=E("div",{class:"pdk-dns-benchmark__notice"});
  const endpointNotice=E("div",{class:"pdk-dns-benchmark__notice"});
  const draftNotice=E("div",{class:"pdk-dns-benchmark__notice",hidden:true},"Проверяются рабочая конфигурация и сохранённый каталог. Черновики не применяются.");
  const bootstrapStatus=E("div",{"aria-live":"polite"});
  const reserveStatus=E("div",{"aria-live":"polite"});
  let lightSelection=null, selectBoth, applyBoth, testLight;
  let savedReserve="";
  let persistedReserve=null, reserveTarget=null, reserveLoading=true;
  let reserveReadiness={}, readinessCheckedReport='';
  let recommend, recommendFull, recommendVerified, recommendReserve, saveReserve, testBootstrap, start, startPairs, test, apply, cancel, rollback, close;

  function pair() {
    const row = mainCandidates().find(r => r.id + ":" + r.protocol + ":" + r.dnsServer === mainSelect.value);
    const bootstrap=bootstrapCandidates().find(r=>bootstrapValue(r)===bootstrapSelect.value);
    return row && bootstrap ? {protocol: row.protocol, id: row.id, dnsServer: row.dnsServer, bootstrapDnsServer: bootstrap.server, bootstrapProtocol: bootstrap.protocol || "udp"} : null;
  }
  function bootstrapValue(row) { return (row.protocol || "udp")+":"+row.server; }
  function precheckCandidate(row) { return row.reliable===true || row.precheckUsable===true; }
  function selectableCandidate(row,bootstrap) {
    return precheckCandidate(row) || state.report.pairResults.some(pair=>(pair.success || pair===state.report.latestPairFailure) && (bootstrap ? (pair.bootstrapProtocol || "udp")===row.protocol && pair.bootstrapDnsServer===row.server : pair.protocol===row.protocol && pair.id===row.id && pair.dnsServer===row.dnsServer));
  }
  function mainCandidates() { return catalogCandidates(state.report,state.catalog,false).filter(row=>row.primaryEligible!==false); }
  function bootstrapCandidates() { return catalogCandidates(state.report,state.catalog,true); }
  function candidateLabel(row,bootstrap) {
    const report=state.report || {results:[],bootstrapResults:[],pairResults:[]};
    const prefix=row.automaticEligible===false?(report.selectionMode==='all_selected'?'только для сравнения · ':'только вручную · '):'';
    const failure=report.latestPairFailure;
    if(failure && (bootstrap ? (failure.bootstrapProtocol||'udp')===row.protocol && failure.bootstrapDnsServer===row.server : failure.protocol===row.protocol && failure.id===row.id && failure.dnsServer===row.dnsServer)) return prefix+'последняя проверка пары: ошибка';
    const passed=report.pairResults.filter(p=>p.success && p.httpsTested!==false && (bootstrap ? (p.bootstrapProtocol||'udp')===row.protocol && p.bootstrapDnsServer===row.server : p.protocol===row.protocol && p.id===row.id && p.dnsServer===row.dnsServer));
    if(passed.length) return prefix+(passed.some(p=>p.measurementProfile!=='minute_sample')?'пара проверена':report.measurementProfile==='minute_sample'?'экспресс-проверка пары':'предыдущая экспресс-проверка пары');
    const measured=(bootstrap?report.bootstrapResults:report.results).find(r=>bootstrap ? bootstrapValue(r)===bootstrapValue(row) : r.id===row.id && r.protocol===row.protocol && r.dnsServer===row.dnsServer);
    return prefix+(measured && measured.measured!==false ? (measured.precheckOnly?((measured.quickReliable ?? measured.reliable)?'DNS отвечает; HTTPS не проверен':'ошибки DNS; HTTPS не проверен'):measured.reliable?'DNS проверен':'есть ошибки') : 'не проверен');
  }
  function plannedPairs() { return (state.report?.results.filter(r=>precheckCandidate(r) && r.primaryEligible!==false).length || 0)*(state.report?.bootstrapResults.filter(precheckCandidate).length || 0); }
  function actions() {
    const busy = state.running || state.pending || state.needsReload;
    selectBoth.disabled=busy;
    applyBoth.disabled=busy || !lightSelection;
    testLight.disabled=busy || !pair();
    recommend.disabled = busy;
    recommendFull.disabled = busy;
    recommendVerified.disabled = busy;
    recommendReserve.disabled = busy;
    testBootstrap.disabled = busy || !pair();
    saveReserve.disabled = busy || reserveLoading || !reserveSaveReady() || !state.report?.reserve || !state.report.fullVerificationComplete || !state.report.recommendation || savedReserve===reserveKey(state.report.recommendation) || !pair() || !pairMatches(pair(),state.report.recommendation);
    start.disabled = busy; test.disabled = busy || !pair() || !bootstrapSelect.value;
    startPairs.disabled = busy || plannedPairs()===0;
    modeTabs.forEach(tab=>{tab.disabled=busy;});
    apply.disabled = busy || state.report?.reserve || !pair() || state.verified !== pairKey(pair());
    cancel.disabled = !state.running || ["apply", "select_apply", "rollback", "reserve_save"].includes(state.action);
    rollback.disabled = busy || !state.backup;
    close.disabled = state.needsReload || state.pending || state.running && ["apply", "select_apply", "rollback", "reserve_save"].includes(state.action);
  }
  function reserveKey(value) { return JSON.stringify([value?.protocol || value?.dnsType,value?.dnsServer,value?.bootstrapProtocol || value?.bootstrapDnsType || 'udp',value?.bootstrapDnsServer]); }
  function reserveSaveReady() { return !!state.report?.reportId && reserveReadiness.saveReady===true && reserveReadiness.saveReportId===state.report.reportId; }
  function reconcileReserveFields(value) {
    if(!value?.dnsServer || !value?.bootstrapDnsServer) return;
    const values={secondary_dns_enabled:value.enabled?'1':'0',secondary_dns_type:value.dnsType,secondary_dns_server:value.dnsServer,secondary_bootstrap_dns_type:value.bootstrapDnsType,secondary_bootstrap_dns_server:value.bootstrapDnsServer};
    // Rebase only clean reserve fields. LuCI caches cfgvalue separately from UCI;
    // leaving either stale would turn a later ordinary Save into an overwrite.
    Object.entries(values).forEach(([name,next])=>{
      if(typeof next!=='string') return;
      const option=map?.lookupOption?.(name,'settings')?.[0];
      const changes=uci.state?.changes?.podkop?.settings;
      const deletes=uci.state?.deletes?.podkop?.settings;
      if(changes && Object.hasOwn(changes,name) || deletes===true || deletes && Object.hasOwn(deletes,name)) return;
      const baseline=option?.cfgvalue?.('settings') ?? option?.default ?? uci.state?.values?.podkop?.settings?.[name] ?? '';
      const current=option?.formvalue?.('settings');
      if(current!=null && String(current)!==String(baseline)) return;
      if(option?.cfgvalue && option?.getUIElement) {
        option.getUIElement('settings')?.setValue(next);
        option.cfgvalue('settings',next);
      }
      const loaded=uci.state?.values?.podkop?.settings;
      if(loaded) loaded[name]=next;
    });
  }
  function showReserveStatus() {
    const winner=state.report?.reserve && state.report.recommendation;
    const saved=winner && savedReserve===reserveKey(winner);
    reserveStatus.textContent=saved ? `Резерв сохранён: ${persistedReserve.dnsServer} + ${persistedReserve.bootstrapDnsServer}. ${persistedReserve.enabled && persistedReserve.autoFailoverEnabled ? 'Авторезерв включён.' : 'Авторезерв выключен.'} Основной DNS не изменён. Черновики формы не сохранены.` : winner ? 'Резерв не сохранён. Нажмите «Сохранить резерв»; остальные черновики формы не сохраняются.' : persistedReserve?.dnsServer ? `Сохранённый резерв: ${persistedReserve.dnsServer} + ${persistedReserve.bootstrapDnsServer}.` : '';
    if(winner && !saved && !reserveLoading && !reserveSaveReady()) reserveStatus.textContent=reserveReadiness.saveError ? errorMessage(reserveReadiness.saveError) : 'Резерв не сохранён. Повторите подбор резерва: подтверждение сохранения отсутствует или настройки изменились.';
    if(winner) recommendationNotice.textContent=`Резервная пара: ${winner.dnsServer} + ${winner.bootstrapDnsServer}. Без ${state.report.excludedProvider}; полностью проверена. ${saved?'Сохранена как резерв.':'Резерв не сохранён.'}`;
  }
  async function readReserve(target) {
    const result=await request(['reserve_status']);
    if(result.success!==true) throw new Error(ERRORS.request_failed);
    reserveReadiness={saveReady:result.saveReady,saveReportId:result.saveReportId,saveError:result.saveError};
    readinessCheckedReport=state.report?.reportId || '';
    persistedReserve=result.reserve || null;
    savedReserve=persistedReserve?.enabled===true && persistedReserve?.dnsServer && persistedReserve?.bootstrapDnsServer ? reserveKey(persistedReserve) : '';
    if(target && savedReserve!==reserveKey(target)) throw new Error('Не удалось подтвердить сохранение резерва. Проверьте состояние и повторите сохранение.');
    reconcileReserveFields(persistedReserve);
    showReserveStatus();
  }
  function resetVerification() { state.verified = ""; pairStatus.textContent = "Проверьте выбранную пару перед применением."; actions(); }
  mainSelect.addEventListener("change", resetVerification);
  bootstrapSelect.addEventListener("change", resetVerification);
  function renderCatalog() {
    const previousMain=mainSelect.value, previousBootstrap=bootstrapSelect.value;
    const mains=mainCandidates(), bootstraps=bootstrapCandidates();
    mainSelect.replaceChildren(...mains.map(row=>E("option",{value:row.id+":"+row.protocol+":"+row.dnsServer},row.protocol.toUpperCase()+" · "+row.dnsServer+" · "+candidateLabel(row,false))));
    bootstrapSelect.replaceChildren(...bootstraps.map(row=>E("option",{value:bootstrapValue(row)},row.protocol.toUpperCase()+" · "+row.server+" · "+row.provider+" · "+candidateLabel(row,true))));
    catalogNotice.textContent=`Каталог: DNS — ${mains.length}, bootstrap — ${bootstraps.length}. Непроверенные варианты не считаются рабочими.`;
    mainSelect.value=mains.some(row=>row.id+":"+row.protocol+":"+row.dnsServer===previousMain)?previousMain:mains.length?mains[0].id+":"+mains[0].protocol+":"+mains[0].dnsServer:"";
    bootstrapSelect.value=bootstraps.some(row=>bootstrapValue(row)===previousBootstrap)?previousBootstrap:bootstraps.length?bootstrapValue(bootstraps[0]):"";
    return {previousMain,previousBootstrap,mains,bootstraps};
  }
  function renderResults(raw) {
    state.report = normalizeReport(raw);
    if(state.report.reserve) state.verified="";
    if(state.report.verifiedWorkflow && !state.report.fullVerificationComplete) state.verified="";
    // Progress polling must not recreate the controls or their expanded details.
    const snapshot=JSON.stringify({...state.report,elapsedSeconds:0,action:raw.action});
    if(snapshot===resultsSnapshot) return;
    resultsSnapshot=snapshot;
    const groups=[["Основной DNS",state.report.results,false],["Bootstrap DNS",state.report.bootstrapResults,true]];
    const panels=groups.map(([title,rows,bootstrap]) => E("section",{"aria-label":title},[
      E("div",{class:"pdk-dns-benchmark__scroll",tabindex:0,"aria-label":title+": результаты"},E("table",{},[
        E("thead",{},E("tr",{},["Сервер","Протокол","Ответы","Среднее","Состояние"].map(text=>E("th",{},text)))),
        E("tbody",{},rows.map(row=>E("tr",{},[
          E("td",{"data-label":"Сервер"},[E("strong",{},String(row.provider || "DNS")),E("small",{},String(bootstrap?row.server:row.dnsServer))]),
          E("td",{"data-label":"Протокол"},row.protocol.toUpperCase()),
          E("td",{"data-label":"Ответы"},row.measured===false && row.successCount==null ? "—" : row.successCount+" / "+row.totalQueries),
          E("td",{"data-label":"Среднее"},row.averageMs == null ? "—" : row.averageMs.toFixed(1)+" мс"),
          E("td",{"data-label":"Состояние"},row.measured===false ? "Отдельно не измерялся" : row.precheckOnly ? [precheckStateText(row),E("small",{},"HTTPS не проверен")] : row.reliable ? "Работает" : E("details",{},[
            E("summary",{},row.totalQueries ? "Есть ошибки" : "Недоступен"),
            E("p",{},row.error ? errorMessage(row.error) : "Проверка не пройдена"),
            ...queryFailureNodes(row),
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
    const {previousMain,previousBootstrap,mains,bootstraps}=renderCatalog();
    // Reopening a completed manual test must display its tuple, not catalog defaults.
    const tested=raw.action==='pair_test' && raw.state==='done' && raw.pairResult;
    if(!previousMain && !previousBootstrap && tested && mains.some(row=>row.id===tested.id && row.protocol===tested.protocol && row.dnsServer===tested.dnsServer) && bootstraps.some(row=>(row.protocol || 'udp')===(tested.bootstrapProtocol || 'udp') && row.server===tested.bootstrapDnsServer)) {
      mainSelect.value=tested.id+':'+tested.protocol+':'+tested.dnsServer;
      bootstrapSelect.value=(tested.bootstrapProtocol || 'udp')+':'+tested.bootstrapDnsServer;
    }
    const fast=state.report.selectionMode==='fast';
    const staged=state.report.selectionMode==='two_stage';
    matrixNotice.textContent=staged ? stagedSearchText(state.report) : state.report.selectionMode==="all_selected" ? selectedSearchText(state.report) : fast ? fastSearchText(state.report) : plannedPairs() ? `Пар для проверки: ${plannedPairs()}.` : "Запустите подбор.";
    const winner=state.report.recommendation;
    recommendationNotice.textContent=winner ? `Рекомендуется: ${winner.protocol.toUpperCase()} · ${winner.dnsServer} + ${(winner.bootstrapProtocol || "udp").toUpperCase()} · ${winner.bootstrapDnsServer}. ${state.report.verifiedWorkflow?"Первая полностью проверенная; не полный перебор.":staged?"Среди финалистов, не всего каталога.":state.report.selectionMode==="all_selected"?"Лучшая из всех выбранных.":fast?(state.report.comparisonComplete?"Лучшая среди проверенных.":"Без сравнительного отбора."):"Из проверенного набора."} Не применено.` : "";
    if(state.report.verifiedWorkflow) {
      matrixNotice.textContent += ` Полная проверка лидеров: попыток ${state.report.fullVerificationAttempts}; ошибок ${state.report.fullVerificationResults.filter(row=>!row.success).length}.`;
      if(winner) recommendationNotice.textContent += " Полная проверка пройдена.";
    }
    if(state.report.reserve) recommendationNotice.textContent=winner ? `Резервная пара: ${winner.dnsServer} + ${winner.bootstrapDnsServer}. Без ${state.report.excludedProvider}; полностью проверена. Не применено.` : "Подбираем резерв; основной DNS не меняется.";
    if(winner && RECOMMENDATION_ACTIONS.includes(raw.action) && pairKey(winner)!==lastRecommendation) {
      lastRecommendation=pairKey(winner);
      mainSelect.value=winner.id+":"+winner.protocol+":"+winner.dnsServer;
      bootstrapSelect.value=(winner.bootstrapProtocol || "udp")+":"+winner.bootstrapDnsServer;
      state.verified=!state.report.reserve && state.report.fullVerificationComplete && pair() && pairMatches(pair(),raw.pairResult)?pairKey(pair()):"";
      pairStatus.textContent=state.report.reserve?"Резерв проверен; основной DNS не применяется.":state.verified?"Пара проверена; ещё не применена.":"Перед применением проверьте пару.";
    }
    showReserveStatus();
    if(state.report.testedSections.length) matrixNotice.textContent += " Секции: "+state.report.testedSections.join(", ")+".";
    matrixDetails.hidden = !state.report.pairResults.length;
    matrixSummary.textContent = "Все результаты DNS-пар (" + state.report.pairResults.length + ")";
    const working=row=>row.success && row.httpsTested!==false && !(row.rechecked===false && row.confirmations?.length);
    const rankGroup=row=>working(row)?0:row.httpsTested===false && row.success?1:2;
    const score=row=>[row.stableScoreMs,row.stats?.scoreMs,row.stats?.averageMs].find(Number.isFinite) ?? Infinity;
    const ranked=[...state.report.pairResults].sort((a,b)=>{
      const recommended=row=>winner && pairKey(winner)===pairKey(row) ? 0 : 1;
      return recommended(a)-recommended(b) || rankGroup(a)-rankGroup(b) ||
        (working(a) && working(b) ? (a.stats?.retryCount || 0)-(b.stats?.retryCount || 0) || score(a)-score(b) : 0);
    });
    const scrollTop=matrixScroll.scrollTop || 0;
    const viewport=matrixScroll.getBoundingClientRect?.();
    const anchor=viewport && scrollTop>0 ? [...matrixRows].map(([key,entry])=>({key,top:entry.node.getBoundingClientRect().top,bottom:entry.node.getBoundingClientRect().bottom})).filter(row=>row.bottom>viewport.top).sort((a,b)=>a.top-b.top)[0] : null;
    const liveKeys=new Set();
    ranked.forEach((row,index)=>{
      const key=pairKey(row), previous=matrixRows.get(key);
      liveKeys.add(key);
      const selectable=mainCandidates().some(candidate=>candidate.id===row.id && candidate.protocol===row.protocol && candidate.dnsServer===row.dnsServer) && bootstrapCandidates().some(candidate=>candidate.protocol===(row.bootstrapProtocol || 'udp') && candidate.server===row.bootstrapDnsServer);
      const signature=JSON.stringify([row,!!winner && pairKey(winner)===key,selectable]);
      let entry=previous;
      if(!entry || entry.signature!==signature) {
        let details;
        const node=E("tr",{},[
        E("td",{"data-label":"Основной DNS"},[row.protocol.toUpperCase(),E("small",{},row.dnsServer)]),
        E("td",{"data-label":"Bootstrap DNS"},[(row.bootstrapProtocol || "udp").toUpperCase(),E("small",{},row.bootstrapDnsServer)]),
        E("td",{"data-label":"Базовый DNS"},row.stats ? `${row.stats.successCount} / ${row.stats.totalQueries}` : "—"),
        E("td",{"data-label":"Среднее DNS"},Number.isFinite(row.stats?.averageMs)?row.stats.averageMs.toFixed(1)+" мс":"—"),
        E("td",{"data-label":"Оценка DNS + HTTPS"},row.success && row.httpsTested!==false && Number.isFinite(row.stats?.scoreMs)?row.stats.scoreMs.toFixed(1)+" мс":"—"),
        E("td",{"data-label":"Через Podkop"},details=E("details",{},[
          E("summary",{},winner && pairKey(winner)===pairKey(row)?"Рекомендуется":pairSummary(row)),
          E("p",{},row.httpsTested===false && row.success?"Проверены только DNS-ответы. HTTPS и маршруты сервисов не проверены; это не подтверждение рабочей пары.":row.success?(row.rechecked===false && row.confirmations?.length?"Первичная проверка прошла, но результат не подтвердился повторно.":"Контрольные DNS- и защищённые соединения прошли. Ответ сайта не гарантирует вход в аккаунт или работу приложения."):errorMessage(row.error)),
          ...(row.httpsTested===false && !row.success?[E("p",{},"HTTPS не проверен; проверка пары не завершена.")]:[]),
          ...repeatFailureNodes(row),
          ...(endpointContext(row)?[E("p",{},endpointContext(row))]:[]),
          ...queryFailureNodes(row.stats),
          ...(row.stats?.retryCount>0?[E("p",{},`Повторов: ${row.stats.retryCount}; успешных: ${row.stats.recoveredRetries || 0}. Разовый сбой учтён при выборе пары.`)]:[]),
          ...(row.transportError?[E("p",{},transportFailureText(row.transportError))]:[]),
          ...(Array.isArray(row.sectionResults)?row.sectionResults.flatMap(section=>[E("p",{},String(section.section)+": "+(section.success?"проверка пройдена":errorMessage(section.error))),...queryFailureNodes(section,6,section.section),...(section.transportError?[E("p",{},transportFailureText(section.transportError))]:[])]):[]),
        ])),
        E("td",{"data-label":"Действие"},row.success && row.httpsTested!==false && selectable ? E("button",{type:"button",class:"btn",click:()=>{
          mainSelect.value=row.id+":"+row.protocol+":"+row.dnsServer;
          bootstrapSelect.value=(row.bootstrapProtocol || "udp")+":"+row.bootstrapDnsServer;
          resetVerification();pairStatus.textContent="Пара выбрана из результатов. Проверьте её ещё раз перед применением.";
        }},"Выбрать") : "—"),
        ]);
        details.open=previous?.details.open || false;
        entry={node,details,signature};
        if(previous) matrixBody.removeChild(previous.node);
        matrixRows.set(key,entry);
      }
      if(matrixBody.children[index]!==entry.node) matrixBody.insertBefore(entry.node,matrixBody.children[index] || null);
    });
    for(const [key,entry] of matrixRows) if(!liveKeys.has(key)) {matrixBody.removeChild(entry.node);matrixRows.delete(key);}
    matrixScroll.scrollTop=scrollTop;
    if(anchor && matrixRows.has(anchor.key)) matrixScroll.scrollTop += matrixRows.get(anchor.key).node.getBoundingClientRect().top-anchor.top;
  }
  function stopPoll() { if (state.timer != null) window.clearTimeout(state.timer); state.timer=null; }
  async function refresh() {
    stopPoll();
    try {
      const status=await request(["status"]); if (!state.open) return;
      const reloadAfterCompletion=state.running && ["apply","select_apply","rollback"].includes(state.action);
      if (!["idle","running","done","error","cancelled"].includes(status.state)) throw new Error(ERRORS.request_failed);
      state.running=status.state === "running"; state.action=status.action || ""; state.backup=!!status.backupAvailable;
      progress.value=Math.min(100,Math.max(0,Number(status.progress)||0));
      count.textContent=(status.total ? `${status.phase==='full_verify'?'Полные проверки':status.state!=='done' && status.phase==='recheck'?'Повторно':(['pairs',...RECOMMENDATION_ACTIONS].includes(status.action)&&status.phase!=='endpoints'||status.phase==='pairs')?'Пары':'Проверено'}: ${status.completed || 0} / ${status.total}` : "")+(status.queryTotal ? ` · Запросы: ${status.queryCompleted || 0} / ${status.queryTotal}` : "");
      if(state.running && typeof status.currentSection==='string' && status.currentSection) count.textContent += ` · Секция: ${status.currentSection} · DNS: ${status.sectionQueryCompleted || 0} / ${status.sectionQueryTotal || 0} · HTTPS: ${status.sectionHttpsCompleted || 0}`;
      if(status.action!=='select') { lightSelection=null; resultTables.hidden=false; }
      if(status.action==='select') {
        resultTables.hidden=true; matrixDetails.hidden=true; matrixNotice.textContent="";
        lightSelection=normalizeLightSelection(status);
        recommendationNotice.textContent=lightSelection
          ? `Основная: ${lightSelection.primary.dnsServer} + ${lightSelection.primary.bootstrapDnsServer}. Резервная: ${lightSelection.secondary.dnsServer} + ${lightSelection.secondary.bootstrapDnsServer}. Проверены DNS-ответы, не приложения. Не применено.`
          : status.state==='running'?'Подбираем основную и независимую резервную пары…':'Подбор неполный: '+errorMessage(status.error || 'independent_reserve_unavailable');
      }
      if (status.action!=='reserve_save' && Array.isArray(status.results) && Array.isArray(status.bootstrapResults)) renderResults(status);
      else if(state.running && RECOMMENDATION_ACTIONS.includes(status.action)) renderResults({...status,results:[],bootstrapResults:[],pairResults:[]});
      if(status.action==='recommend_reserve' && status.state==='done' && state.report?.reportId && !reserveLoading && readinessCheckedReport!==state.report.reportId) await readReserve();
      error.textContent="";
      const bootstrapProof=status.action==='bootstrap_test'?status.bootstrapTest:status.recommendationBootstrapTest;
      if(bootstrapProof) {
        bootstrapStatus.textContent=`Bootstrap ${(bootstrapProof.protocol || "").toUpperCase()} · ${String(bootstrapProof.server || "")}: ${bootstrapProof.success?"проверен":"не прошёл"}. Отдельный DNS-тест, не HTTPS.`;
        if(bootstrapProof.error) bootstrapStatus.append(E("div",{},errorMessage(bootstrapProof.error)));
        if(Array.isArray(bootstrapProof.checks)) bootstrapStatus.append(...bootstrapProof.checks.map(check=>E("div",{},`${String(check.domain || '')}: ${check.success?'ответ получен':'ошибка'}${check.reason?' · '+String(check.reason):''}`)));
      }
      if (state.running) {
        if(status.selectionMode==='two_stage') matrixNotice.textContent=stagedSearchText(status);
        else if(status.selectionMode==='all_selected') matrixNotice.textContent=selectedSearchText(status);
        else if(status.selectionMode==='fast') matrixNotice.textContent=fastSearchText(status);
        if(['recommend_verified','recommend_reserve'].includes(status.action)) matrixNotice.textContent += ` Полная проверка лидеров: попыток ${state.report?.fullVerificationAttempts || 0}; ошибок ${state.report?.fullVerificationResults.filter(row=>!row.success).length || 0}.`;
        message.textContent=state.action==='reserve_save' ? 'Сохраняем резерв…' : RECOMMENDATION_ACTIONS.includes(state.action) ? (status.phase==='full_verify'?"Полная проверка лидеров…":status.phase==='pairs'?"Проверяем пары через секции Podkop…":status.phase==='recheck'?"Повторно проверяем лучшие пары…":"Проверяем доступность DNS-кандидатов…") : state.action === "pairs" ? "Проверяем пары через текущие маршруты Podkop…" : state.action === "pair_test" ? "Проверяем выбранную пару и доступность сервисов…" : state.action === "apply" ? "Применяем DNS и проверяем работу Podkop…" : state.action === "rollback" ? "Восстанавливаем предыдущие DNS…" : "Измеряем DNS-кандидатов…";
        state.timer=window.setTimeout(refresh,1000);
      } else if (status.state === "error") {
        if(status.action==='reserve_save') showReserveStatus();
        error.textContent=errorMessage(status);
        if(endpointContext(status.pairResult)) error.textContent += " "+endpointContext(status.pairResult);
        const transport=status.pairResult?.transportError;
        if (transport) error.textContent += " ("+transportFailureText(transport)+")";
        const sections=status.pairResult?.sectionResults;
        if(Array.isArray(sections)) sections.filter(section=>section?.success===false && section.transportError).forEach(section=>{error.textContent += " · "+String(section.section)+": "+transportFailureText(section.transportError);});
        error.append(...queryFailureNodes(status.pairResult?.stats));
        if(Array.isArray(sections)) error.append(...sections.filter(section=>section?.success===false).flatMap(section=>queryFailureNodes(section,6,section.section)));
        message.textContent="Операция не выполнена"; state.verified="";
      }
      else if (status.action === "light_pair" && status.state === "done") {
        state.verified="";
        message.textContent=status.pairResult?.success===true?"DNS-цепочка отвечает. Приложения и маршруты не проверялись.":errorMessage(status.error || "pair_test_failed");
      }
      else if (status.action === "select" && status.state === "done") {
        message.textContent=lightSelection?"Обе пары подобраны. Применение — отдельно.":"Нет подтверждённого результата для обеих пар. DNS не изменены.";
      }
      else if (status.action === "benchmark" && status.state === "done" && status.phase === "quick_endpoints") {
        state.verified="";
        message.textContent=status.budgetExhausted ? "Лимит 60 секунд достигнут. Показаны только выполненные замеры DNS." : "Быстрый тест DNS завершён.";
        pairStatus.textContent="Проверены только ответы DNS. HTTPS и маршруты сервисов не проверены; перед применением проверьте выбранную пару.";
        recommendationNotice.textContent="";
        matrixNotice.textContent="Рабочий Podkop и DNS не изменены. Автоматического применения нет.";
      }
      else if (status.state === "cancelled") { message.textContent=ERRORS.cancelled; state.verified=""; }
      else if(status.action==='reserve_save' && status.state==='done') {
        await readReserve(reserveTarget); reserveTarget=null;
        message.textContent='Резерв сохранён. Рабочий DNS не применялся.';
      }
      else if(status.action==='bootstrap_test' && status.state==='done') {
        state.verified=""; message.textContent="Отдельная проверка bootstrap завершена. DNS не изменены.";
      }
      else if (status.action === "pair_test" && status.state === "done") {
        const success=pair() && pairMatches(pair(),status.pairResult);
        state.verified=success?pairKey(pair()):"";
        pairStatus.textContent=success?"Пара проверена; ещё не применена.":ERRORS.pair_test_failed;
        endpointNotice.textContent=endpointContext(status.pairResult);
        if(!success && endpointContext(status.pairResult)) pairStatus.textContent += " "+endpointContext(status.pairResult);
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
      } else { message.textContent=RECOMMENDATION_ACTIONS.includes(status.action) ? (state.report?.recommendation?"Подбор завершён. Рекомендация готова, DNS не изменены.":"Подбор завершён без подтверждённой рекомендации. DNS не изменены.") : status.action==="pairs" ? "Проверка пар завершена. Выберите рабочую пару." : state.report?"Измерения завершены. Выберите и проверьте пару.":"Готов к проверке"; }
    } catch (failure) { error.textContent=failure.message || ERRORS.request_failed; if(state.action==='reserve_save' && !state.running)showReserveStatus();if(state.running && state.open)state.timer=window.setTimeout(refresh,1500); }
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
      const dirty=await hasChanges();
      if(["apply_start","apply_selected_start","rollback_start"].includes(command) &&
          map?.root?.querySelector('[data-changed="true"]')) throw new Error(ERRORS.unsaved_changes);
      draftNotice.hidden=!dirty;
      lightSelection=null;
      reserveReadiness={};readinessCheckedReport='';
      state.verified=""; pairStatus.textContent="";
      if(RECOMMENDATION_ACTIONS.some(action=>command===action+'_start')) lastRecommendation="";
      recommendationNotice.textContent="";
      bootstrapStatus.textContent="";bootstrapStatus.replaceChildren();
      const accepted=await request([command,...args]);
      if (accepted.success !== true) throw new Error(ERRORS.request_failed);
      state.running=true; state.action=command==='apply_selected_start'?'select_apply':command.replace(/_start$/,"");
      if(RECOMMENDATION_ACTIONS.includes(state.action)) renderResults({action:state.action,results:[],bootstrapResults:[],pairResults:[],selectionMode:state.action==='recommend_full'?'all_selected':'two_stage',selectionComplete:false});
      await refresh();
    } catch(failure) { error.textContent=failure.message || ERRORS.request_failed; }
    finally {state.pending=false;actions();}
  }
  function makeButton(label,fn,kind="cbi-button-action") { return E("button",{type:"button",class:"cbi-button "+kind,click:event=>{event.preventDefault();return fn();}},label); }
  recommend=makeButton("Подобрать рабочую пару",()=>operate("recommend_start"));
  recommendFull=makeButton("Полный перебор всех пар",()=>operate("recommend_full_start"),"cbi-button-neutral");
  recommendVerified=makeButton("Подобрать и полностью проверить",()=>operate("recommend_verified_start"));
  recommendReserve=makeButton("Подобрать резервную пару",()=>operate("recommend_reserve_start"));
  saveReserve=makeButton("Сохранить резерв",async()=>{
    if(saveReserve.disabled) return;
    const winner=state.report.recommendation;
    state.pending=true;reserveTarget=winner;actions();error.textContent='';
    reserveStatus.textContent='Сохраняем резерв…';
    try {
      const accepted=await request(['reserve_save_start',...pairArgs(winner)]);
      if(accepted.success!==true) throw new Error(ERRORS.request_failed);
      state.running=true;state.action='reserve_save';
      await refresh();
    } catch(failure) {
      try { await readReserve(winner);message.textContent='Резерв сохранён. Рабочий DNS не применялся.'; }
      catch(_readbackFailure) {error.textContent=failure.message || ERRORS.request_failed;showReserveStatus();}
    }
    finally {state.pending=false;actions();}
  },"cbi-button-neutral");
  selectBoth=makeButton("Подобрать обе пары",()=>operate("select_start"));
  applyBoth=makeButton("Применить обе пары",()=>lightSelection && operate("apply_selected_start",[lightSelection.reportId]),"cbi-button-apply");
  start=makeButton("Быстрый тест DNS",()=>operate("benchmark_start"));
  startPairs=makeButton("Проверить пары",()=>operate("pairs_start"));
  function pairArgs(selected) { return [selected.protocol,selected.id,selected.dnsServer,selected.bootstrapDnsServer,selected.bootstrapProtocol]; }
  test=makeButton("Проверить пару",()=>{const selected=pair();return selected && operate("pair_test_start",pairArgs(selected));});
  testLight=makeButton("Лёгкая проверка пары",()=>{const selected=pair();return selected && operate("light_pair_start",pairArgs(selected));});
  testBootstrap=makeButton("Проверить bootstrap",()=>{const selected=pair();return selected && operate("bootstrap_test_start",[selected.bootstrapProtocol,selected.bootstrapDnsServer,selected.protocol,selected.dnsServer]);});
  apply=makeButton("Применить пару",()=>{const selected=pair();return selected && state.verified===pairKey(selected) && operate("apply_start",pairArgs(selected));},"cbi-button-apply");
  rollback=makeButton("Откатить DNS",()=>operate("rollback_start"),"cbi-button-reset");
  cancel=makeButton("Отменить проверку",async()=>{if(["apply","select_apply","rollback"].includes(state.action))return;try{await request(["cancel"]);await refresh();}catch(failure){error.textContent=failure.message;}},"cbi-button-reset");
  close=makeButton("Закрыть",()=>{if(close.disabled)return;state.open=false;stopPoll();ui.hideModal();if(state.running)request(["cancel"]).catch(()=>{});},"cbi-button-reset");
  const modeTabs=["1. Серверы по отдельности","2. Пары через Podkop"].map((label,index)=>makeButton(label,()=>showMode(index===0?"individual":"pairs")));
  function showMode(mode) {
    state.mode=mode; const matrix=mode==="pairs";
    resultTables.hidden=matrix;start.hidden=false;startPairs.hidden=!matrix;
    modeTabs.forEach((tab,index)=>tab.setAttribute("aria-pressed",String((index===1)===matrix)));
  }
  showMode("individual");
  const content=E("div",{class:"pdk-dns-benchmark"},[
    E("div",{class:"pdk-dns-benchmark__notice"},"Автоматического применения нет. Закрытие окна отменяет проверку."),
    E("a",{href:"https://github.com/moz9/podkop-patch-subscriptions/blob/pe-dns-pairs-20261007/docs/user-guide.md",target:"_blank",rel:"noopener noreferrer"},"Справка"),
    E("div",{class:"pdk-dns-benchmark__notice"},"Подбор обеих пар: до 60 секунд, без дополнительного движка. Проверяются DNS-ответы и независимость резерва, не работа приложений. Применение и откат — отдельными кнопками."),
    E("div",{class:"pdk-dns-benchmark__toolbar"},[selectBoth,applyBoth,message,progress,count,cancel]),error,recommendationNotice,matrixNotice,matrixDetails,resultTables,
    E("details",{},[E("summary",{},"Отдельные измерения и диагностика"),
      endpointNotice,
      E("div",{class:"pdk-dns-benchmark__notice"},"Проверка пар через Podkop и полный подбор — отдельные, более длительные режимы. Они могут потребовать дополнительной памяти. DNS не применяются автоматически."),
      E("div",{class:"pdk-dns-benchmark__toolbar"},[start,test,recommend,recommendVerified,recommendReserve,recommendFull]),
      E("div",{class:"pdk-dns-benchmark__tabs","aria-label":"Режим проверки DNS"},modeTabs),
      E("div",{class:"pdk-dns-benchmark__toolbar"},[startPairs])]),
    draftNotice,catalogNotice,E("div",{class:"pdk-dns-benchmark__pair"},[
      E("label",{},["Основной DNS",mainSelect]),E("label",{},["Bootstrap DNS",bootstrapSelect]),
    ]),pairStatus,bootstrapStatus,reserveStatus,E("div",{class:"pdk-dns-benchmark__footer"},[testLight,testBootstrap,saveReserve,apply,rollback,close]),
  ]);
  actions();ui.showModal("Бенчмарк DNS",[content]);refresh();
  // Load immutable choices once per dialog, independently of measurement cache.
  request(["catalog"]).then(value=>{
    if(!state.open) return;
    state.catalog=normalizeReport({...value,state:"idle",results:[],bootstrapResults:[],pairResults:[]});
    renderCatalog();actions();
  }).catch(()=>{if(state.open && !mainCandidates().length) catalogNotice.textContent="Не удалось прочитать встроенный каталог DNS. Подбор обеих пар остаётся отдельной операцией.";});
  readReserve().catch(failure=>{reserveStatus.textContent='Не удалось прочитать сохранённый резерв: '+(failure.message || ERRORS.request_failed);}).finally(()=>{reserveLoading=false;if(state.open){showReserveStatus();actions();}});
}

function renderOpenButton(map) {
  return E("button",{type:"button",class:"cbi-button cbi-button-action",click:event=>{event.preventDefault();openBenchmark(map);}},"Открыть бенчмарк DNS");
}

return baseclass.extend({normalizeLightSelection,catalogCandidates,renderOpenButton,normalizeReport,pairMatches,pairSummary,errorMessage,precheckStateText});
