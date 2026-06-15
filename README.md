# Podkop Subscription URLTest Patch

Этот репозиторий не является форком и не содержит исходный код Podkop.

Оригинальный проект: [itdoginfo/podkop](https://github.com/itdoginfo/podkop).
Здесь хранится только патч для добавления режима `Subscription URLTest` и вкладки управления конфигами подписок.

## Что добавляет патч

- режим `Subscription URLTest` для чтения proxy-конфигов из HTTP/HTTPS подписок;
- поддержку нескольких подписок в одной секции;
- кеш последней рабочей подписки, чтобы Podkop продолжал работать при ошибке обновления;
- фильтрацию неподдерживаемых Podkop конфигов до генерации sing-box;
- отдельный список неподдерживаемых конфигов в дашборде;
- вкладку `Подписки` в LuCI для включения/исключения отдельных конфигов;
- сохранение исключений по хэшу ссылки, без записи proxy-ссылок в UCI;
- русские строки интерфейса для добавленных элементов.

## Как применить

```bash
git clone https://github.com/itdoginfo/podkop.git
git clone https://github.com/moz9/podkop-patch-subscriptions.git
cd podkop
git am ../podkop-patch-subscriptions/patches/0001-add-subscription-urltest-management.patch
```

Если нужно только проверить применимость:

```bash
git apply --check ../podkop-patch-subscriptions/patches/0001-add-subscription-urltest-management.patch
```

## Файл патча

- [`patches/0001-add-subscription-urltest-management.patch`](patches/0001-add-subscription-urltest-management.patch)

Патч включает также собранный LuCI bundle `main.js`, потому что он хранится в upstream-репозитории Podkop рядом с исходниками frontend.

## Статус

Патч был локально проверен командами:

```bash
npx --yes shellcheck -s sh --severity=error podkop/files/usr/bin/podkop podkop/files/usr/lib/sing_box_config_facade.sh
npm run lint -- --max-warnings=0
npm test -- --run
npm run build
git diff --check
```

Также был smoke-tested на роутере OpenWrt с Podkop и sing-box.
