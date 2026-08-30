# Подпись и notarization

[English version](SIGNING.md)

Mac Utils выпускается по двум каналам в Apple Developer Team `4U4284E89E`:

- `Release-AppStore` работает в App Sandbox и экспортируется с Cloud Managed Apple Distribution и профилем Mac Team Store для `com.witqq.mac-utils`;
- `Release-Direct` использует Hardened Runtime без App Sandbox и экспортируется с Developer ID Application.

В локальном Keychain должны быть действующие identities Apple Development, Developer ID Application и Developer ID Installer. Для Store-экспорта Xcode может использовать управляемую в облаке identity Apple Distribution. Закрытые ключи, app-specific passwords и профили не хранятся в репозитории.

Публичная автоматизация, защищённые environments, имена secrets, версии, повторные запуски и validation/upload Store описаны в документе [Выпуск релизов](RELEASING.ru.md). Локальные профили Keychain не копируются в CI.

## Локальные подписанные архивы

Создайте подписанный архив и distribution export одной из команд:

```sh
./scripts/archive-xcode-local.sh app-store
./scripts/archive-xcode-local.sh direct
```

Скрипт не перезаписывает существующий подписанный артефакт. Результаты находятся в игнорируемых каталогах `.build/xcode-archives/` и `.build/xcode-exports/`.

Перед загрузкой в App Store проверьте архив с `Config/ExportOptions/AppStoreValidate.plist`. Для validation в App Store Connect должна существовать карточка приложения с bundle ID `com.witqq.mac-utils`.

## Direct-приложение и DMG

Передайте `Config/ExportOptions/DeveloperIDNotarize.plist` команде `xcodebuild -exportArchive` с destination `upload`, чтобы отправить Developer ID archive через аккаунт Xcode. После принятия Apple экспортируйте приложение с прикреплённым ticket командой `xcodebuild -exportNotarizedApp`.

Создайте образ из этого приложения и подпишите сам контейнер:

```sh
./scripts/create-dmg.sh \
  "/path/to/Mac Utils.app" \
  "/path/to/Mac-Utils-v1.0.0.dmg" \
  "Developer ID Application"
```

Образ содержит `Mac Utils.app`, ссылку `/Applications`, версионированный фон и заданную раскладку Finder. Отправьте и прикрепите ticket с профилем Keychain:

```sh
./scripts/notarize-dmg.sh "/path/to/Mac-Utils-v1.0.0.dmg" mac-utils-notary
```

Скрипт notarization проверяет подпись контейнера, ticket Apple, оценку Gatekeeper, целостность образа и итоговую контрольную сумму SHA-256. Контрольная сумма вычисляется после stapling, потому что эта операция меняет байты образа.

## Работа с credentials

Сохраняйте данные notarization интерактивно, чтобы app-specific password не попадал в историю shell или файлы репозитория:

```sh
xcrun notarytool store-credentials mac-utils-notary
```

Создавайте и обновляйте сертификаты в **Xcode → Settings → Accounts → Manage Certificates…**. После обновления повторите `security find-identity -v -p basic`, создание подписанного архива и соответствующие проверки Gatekeeper. Не заменяйте отсутствующую release identity подписью ad-hoc.
