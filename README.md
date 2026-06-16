# Podkop Subscription URLTest Patch

Этот репозиторий не является форком Podkop и не содержит исходный код Podkop целиком.

Оригинальный проект: [itdoginfo/podkop](https://github.com/itdoginfo/podkop).

Здесь хранится только патч, который добавляет режим `Subscription URLTest` и вкладку управления конфигами из подписок.

## Установка на OpenWrt одной командой

Выполнить уже внутри SSH-сессии на роутере:

```sh
wget -O /tmp/podkop-subscriptions-install.sh https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/v2026.06.16-subscriptions-speedtest-fix/openwrt/install.sh && sh /tmp/podkop-subscriptions-install.sh
```

Установщик:

- скачивает runtime-патч, LuCI-файлы и русскую локализацию;
- делает резервную копию изменяемых файлов в `/root/podkop-patch-subscriptions-backup-*`;
- по умолчанию хранит только 2 последние резервные копии;
- применяет патч поверх уже установленного Podkop;
- проверяет shell-синтаксис;
- перезагружает Podkop и LuCI;
- при ошибке возвращает файлы из резервной копии.

## Что добавляет патч

- режим `Subscription URLTest` для чтения proxy-конфигов из HTTP/HTTPS подписок;
- поддержку нескольких подписок в одной секции;
- кеш последней рабочей версии подписки;
- фильтрацию неподдерживаемых Podkop конфигов до генерации sing-box;
- отдельный список неподдерживаемых конфигов в дашборде;
- вкладку `Подписки` для включения и исключения отдельных конфигов;
- пакетное применение изменений с одним перезапуском Podkop;
- компактные действия во вкладке `Подписки`: обновить, ping, быстрый тест скорости, обновить патч;
- русские строки интерфейса для добавленных элементов.

## Патч для исходников

Если нужно применить изменения к локальному checkout Podkop:

```sh
git clone https://github.com/itdoginfo/podkop.git
git clone https://github.com/moz9/podkop-patch-subscriptions.git
cd podkop
git am ../podkop-patch-subscriptions/patches/*.patch
```

Runtime-установка для OpenWrt использует отдельные файлы из `openwrt/`.
