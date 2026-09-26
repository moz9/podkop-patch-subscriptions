# Заметки для агентов

## Предложения по улучшению (не утверждены владельцем)

Ниже — находки ревью репозитория от 2026-09-26. Это только предложения:
не реализуйте их без явной просьбы владельца репозитория. Если пункт выполнен
или отклонён, удалите его из списка.

1. **`s` (фоновый безопасный апдейтер) не работает.** Он скачивает 17 файлов
   в `$WORK_DIR/openwrt` и запускает `i` с `PODKOP_PATCH_RAW_BASE=file://…`,
   а `prefetch_patch_assets` в `i` требует 26 файлов. Не хватает
   `dashboard.js`, `diagnostic.js`, `podkop.js`, `podkop-dns-failover`,
   `podkop-dns-failover.init`, `podkop-dns-failover-upgrade.sh`,
   `podkop-subscription-apply-v2-upgrade.sh`,
   `podkop-subscription-sources-upgrade.sh`,
   `podkop-subscription-seamless-reload-upgrade.sh`, `podkop-update-manager`,
   `podkop-update-center-upgrade.sh`. Поэтому установка через `s` падает
   с ошибкой `local source not found`. Лишние в списке `s`:
   `podkop-subscription-urltest-runtime.patch` и
   `podkop-subscription-cache-only-upgrade.patch`. Предложение: синхронизировать
   список и добавить тест, который берёт список файлов из `prefetch_patch_assets`
   в `i` и прогоняет `s` с `PODKOP_PATCH_SAFE_FOREGROUND=1` на локальной копии
   релиза.

2. **Нет проверки целостности кода, выполняемого от root.** Без проверки
   сертификата скачиваются:
   - команда установки в README (`wget --no-check-certificate`);
   - запасной путь по IP с заголовком `Host` в `i`, `s`,
     `openwrt/podkop-update-manager`;
   - основная попытка `wget` в `openwrt/podkop-update-manager` (строка ~177),
     `openwrt/podkop-subscription-apply-v2-upgrade.sh`,
     `openwrt/podkop-subscription-seamless-reload-upgrade.sh` и в `s`.

   Предложение: хранить sha256 всех файлов релиза в
   `openwrt/update-manifest.json` (генерировать скриптом, проверять в
   `tests/test_release_metadata_sync.sh`) и сверять их в `i` до установки.
   Это же защитит от смеси старых и новых файлов из кеша jsDelivr.

3. **Нет CI.** В репозитории нет `.github/workflows`. Предложение: workflow,
   который запускает `sh tests/run.sh` (нужны `sh`, `curl`, Node 22) и
   `shellcheck -s sh -S error` по файлам, исполняемым на роутере.

4. **Ложные отказы изолированного ping/бенча.** В
   `openwrt/podkop-subscription-probe.sh` (и в копиях в
   `openwrt/runtime-*/usr/bin/podkop`) после `sing-box run` стоит фиксированный
   `sleep 1`, затем сразу curl. На медленном роутере порт может ещё не
   слушаться, и живой узел будет показан как `probe_curl_7`. Предложение:
   ждать открытия порта до ~5 с. Изменение затрагивает runtime, поэтому
   нужен бамп версии патча (`INSTALL_MARKER`, манифест, неймспейс LuCI).

5. **Дублирование.** `i` идентичен `openwrt/install.sh`; два runtime
   (`0.7.20` и `0.7.22`) почти одинаковы (~5800 строк каждый); кроме серии
   `patches/` есть отдельные runtime-патчи. Так и разошёлся `s` с `i`.
   Предложение: генерировать копии из одного источника или проверять
   тестом их совпадение.

6. **Мелочь.** В `case "$bytes:$streams:$timeout" in *[!0-9:]*|'')`
   вариант `''` недостижим (в строке всегда есть `:`). Вреда нет: пустые
   значения отсекает следующая проверка `-ge`/`-le`.
