# Podkop Subscription URLTest Patch

Этот репозиторий не является форком Podkop и не содержит исходный код Podkop целиком.

Оригинальный проект: [itdoginfo/podkop](https://github.com/itdoginfo/podkop).
Здесь хранится только патч, который добавляет режим `Subscription URLTest` и вкладку управления конфигами из подписок.

## Установка на OpenWrt одной командой

Выполнить с компьютера, где доступен SSH до роутера:

```sh
ssh -p 22222 root@192.168.77.1 "wget -O /tmp/podkop-subscriptions-install.sh https://raw.githubusercontent.com/moz9/podkop-patch-subscriptions/main/openwrt/install.sh && sh /tmp/podkop-subscriptions-install.sh"
```

Если SSH доступен на стандартном порту 22, уберите `-p 22222`.

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
- сохранение исключений по хэшу ссылки, без записи proxy-ссылок в UCI;
- русские строки интерфейса для добавленных элементов.

## Патч для исходников

Если нужно применить изменение к локальному checkout Podkop:

```sh
git clone https://github.com/itdoginfo/podkop.git
git clone https://github.com/moz9/podkop-patch-subscriptions.git
cd podkop
git am ../podkop-patch-subscriptions/patches/0001-add-subscription-urltest-management.patch
```

Файл патча:

- [`patches/0001-add-subscription-urltest-management.patch`](patches/0001-add-subscription-urltest-management.patch)

Runtime-установка для OpenWrt использует отдельный файл:

- [`openwrt/podkop-subscription-urltest-runtime.patch`](openwrt/podkop-subscription-urltest-runtime.patch)

## Проверка

Патч проверялся локально на чистом checkout Podkop и smoke-тестом на роутере OpenWrt с Podkop и sing-box.
