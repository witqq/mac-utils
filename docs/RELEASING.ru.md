# Выпуск релизов

[English version](RELEASING.md)

Mac Utils использует три GitHub Actions workflow. [CI](../.github/workflows/ci.yml) проверяет каждый pull request и push в `main`. [GitHub Release](../.github/workflows/release.yml) публикует подписанные Direct-сборки из неизменяемых тегов `vMAJOR.MINOR.PATCH`. [App Store](../.github/workflows/app-store.yml) вручную и под защитой валидирует или загружает ту же маркетинговую версию и номер сборки.

## Защищённые environments и credentials

Релизные jobs читают credentials только из GitHub Environment Secrets. Не создавайте их копии на уровне репозитория и никогда не сохраняйте расшифрованные файлы в artifact, cache, log, commit или shell history.

Environment `github-release` разрешает теги `v*` и защищённую `main` для ручных повторных запусков и содержит:

- `DEVELOPER_ID_APPLICATION_P12_BASE64` — base64 экспортированной identity Developer ID Application с закрытым ключом;
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD` — пароль экспорта;
- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` — base64 Team API-ключа App Store Connect в формате `.p8` с ролью Developer, который операционно используется только для notarization;
- `APP_STORE_CONNECT_KEY_ID` и `APP_STORE_CONNECT_ISSUER_ID` — идентификаторы API-ключа.

Environment `app-store` разрешает только защищённую ветку `main`, требует подтверждения владельца и содержит:

- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` — base64 отдельного Team API key с ролью Admin, необходимой Xcode для cloud-managed distribution signing;
- `APP_STORE_CONNECT_KEY_ID` и `APP_STORE_CONNECT_ISSUER_ID` — идентификаторы Store API key.

Individual API key не может аутентифицировать `notarytool`, поэтому оба environments используют Team keys. Разделяйте Developer key для notarization и Admin key для Store: тогда расширенное право cloud signing недоступно jobs GitHub Release. Экспортируйте identity Developer ID Application из Keychain Access в защищённый паролем `.p12`, локально преобразуйте его в base64, вставьте значение в environment `github-release` и удалите экспорт. GitHub-hosted runner декодирует credentials только в `RUNNER_TEMP`, импортирует Direct-сертификат во временный keychain и удаляет оба после job. Store workflow использует свой API key и cloud-managed Apple Distribution и Mac Installer Distribution signing Xcode, поэтому экспорт Store-сертификата и его закрытого ключа не нужен.

## Проверки pull request

CI работает на macOS 26 с Xcode 26.3 и проверяет документацию, локализацию и релизные материалы, выполняет SwiftPM- и Xcode-тесты, статический анализ и сканирование всей Git-истории через Gitleaks. Cache используется только в CI; подписанный релиз всегда начинается с чистого каталога. Все сторонние actions закреплены за неизменяемыми commit SHA, а токен по умолчанию имеет только право чтения.

Перед pull request выполните те же продуктовые проверки:

```sh
./scripts/check-docs.sh
./scripts/check-release-assets.sh
./scripts/test.sh
./scripts/generate-xcode-project.sh
xcodebuild test -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
xcodebuild analyze -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

## Публикация GitHub Release

Перед тегом задайте `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `project.yml`, обновите `CHANGELOG.md`, release notes на обоих языках, metadata, screenshots и landing. Влейте зелёный pull request в защищённую `main`, затем создайте и отправьте тег ровно этого коммита:

```sh
git switch main
git pull --ff-only
git tag -a v1.0.0 -m "Mac Utils v1.0.0"
git push origin v1.0.0
```

Release workflow отклоняет неверный или несовпадающий номер версии. Он создаёт чистый universal Direct archive, подписывает приложение и DMG, отправляет DMG на notarization Apple, прикрепляет и проверяет ticket, рассчитывает SHA-256 и формирует release notes средствами GitHub. Затем он публикует `Mac-Utils-v1.0.0.dmg` и `Mac-Utils-v1.0.0.dmg.sha256`, скачивает оба файла из GitHub, проверяет checksum, подпись, ticket и образ и копирует приложение через DMG-раскладку с `/Applications`.

Повторный запуск безопасен: откройте **Actions → GitHub Release → Run workflow** на `main` и укажите существующий тег. Workflow возьмёт release automation из защищённой `main`, но получит и скомпилирует product source из неизменяемого тега, предварительно проверив принадлежность tagged commit ветке `main`. Он заменит в существующем release только два версифицированных и заново проверенных asset и не создаст второй release. Никогда не переносите и не переписывайте опубликованный тег. Изменение исходников требует новой patch-версии.

## Проверка или загрузка App Store build

Откройте **Actions → App Store → Run workflow** на `main`, укажите маркетинговую версию и номер сборки и сначала выберите `validate`. Подтвердите защищённый deployment `app-store`. Workflow создаст чистый App Store archive, экспортирует подписанный installer package, проверит его через App Store Connect API key и сохранит package на 14 дней. После успешной проверки повторите ту же версию и build с `upload`, только если этот номер ещё не загружен: App Store Connect не принимает повторяющиеся номера сборок.

GitHub release и Store submission для v1.0.0 используют маркетинговую версию `1.0.0` и build `1`. Если последующая Store-сборка меняет исполняемый файл, увеличьте `CURRENT_PROJECT_VERSION` и используйте новый номер во всех местах.

## Аудит после запуска

Убедитесь, что все обязательные jobs зелёные, release содержит ровно DMG и checksum, а Store job сообщает об успешной validation или upload. Проверьте логи на неожиданную трассировку команд и credential material. Маскирование GitHub — запасная защита, а не разрешение печатать secret. Если API key или сертификат появился вне защищённого хранилища, немедленно замените его.
