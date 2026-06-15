# Podkop Subscription URLTest Patch

Этот репозиторий не является форком Podkop и не содержит исходный код Podkop целиком.

Оригинальный проект: [itdoginfo/podkop](https://github.com/itdoginfo/podkop).
Здесь хранится только патч, который добавляет режим `Subscription URLTest` и вкладку управления конфигами из подписок.

## Установка на OpenWrt одной командой

Выполнить уже внутри SSH-сессии на роутере:

```sh
PODKOP_PATCH_VERSION=84afc70ad19c181d45e5ea8af5ec67a17220aeba; wget -O /tmp/podkop-subscriptions-install.sh "https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PODKOP_PATCH_VERSION/openwrt/install.sh" && PODKOP_PATCH_RAW_BASE="https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/$PODKOP_PATCH_VERSION/openwrt" sh /tmp/podkop-subscriptions-install.sh
```

Установщик:

- скачивает runtime-патч и русскую LuCI-переводку;
- делает резервную копию изменяемых файлов в `/root/podkop-patch-subscriptions-backup-*`;
- применяет патч поверх уже установленного Podkop;
- проверяет shell-синтаксис;
- перезагружает Podkop и LuCI;
- при ошибке возвращает файлы из резервной копии.

## Что добавляет патч

- режим `Subscription URLTest` для чтения proxy-конфигов из HTTP/HTTPS подписок;
- поддержку нескольких подписок в одной секции;
- кеш последней рабочей подписки, чтобы Podkop продолжал работать при ошибке обновления;
- фильтрацию неподдерживаемых Podkop конфигов до генерации sing-box;
- отдельный список неподдерживаемых конфигов в дашборде;
- вкладку `Подписки` в LuCI для включения и исключения отдельных конфигов;
- пакетное применение изменений во вкладке `Подписки` с одним перезапуском Podkop;
- сохранение исключений по хэшу ссылки, без записи proxy-ссылок в UCI;
- русские строки интерфейса для добавленных элементов.

## Патч для исходников

Если нужно применить изменение к локальному checkout Podkop:

```sh
git clone https://github.com/itdoginfo/podkop.git
git clone https://github.com/moz9/podkop-patch-subscriptions.git
cd podkop
git am ../podkop-patch-subscriptions/patches/*.patch
```

Файлы патчей:

- [`patches/0001-add-subscription-urltest-management.patch`](patches/0001-add-subscription-urltest-management.patch)
- [`patches/0002-add-batch-subscription-selection-apply.patch`](patches/0002-add-batch-subscription-selection-apply.patch)

Runtime-установка для OpenWrt использует отдельный файл:

- [`openwrt/podkop-subscription-urltest-runtime.patch`](openwrt/podkop-subscription-urltest-runtime.patch)
- [`openwrt/podkop-subscription-batch-upgrade.patch`](openwrt/podkop-subscription-batch-upgrade.patch)

## Проверка

Патч проверялся локально на чистом checkout Podkop и smoke-тестом на роутере OpenWrt с Podkop и sing-box.
