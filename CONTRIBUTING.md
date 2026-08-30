# Contributing

## English

Thank you for improving Mac Utils. Keep changes focused, testable, and consistent with the registry-based architecture.

### Before coding

- Search existing issues and discussions before proposing a duplicate.
- Open a feature proposal before a large UI, architecture, entitlement, or distribution change.
- Read [Architecture](docs/ARCHITECTURE.md), [Extending Mac Utils](docs/EXTENDING.md), and [Security policy](SECURITY.md).
- Never include private configuration, certificates, profiles, tokens, or user data in an issue or commit.

### Development setup

Requirements: macOS 26+, Xcode 26 with command-line tools, Swift 6.2, and XcodeGen 2.46.0+.

```sh
./scripts/build-debug.sh
./scripts/test.sh
./scripts/check-docs.sh
./scripts/generate-xcode-project.sh
```

Use a feature branch. Preserve module boundaries: reusable domain behavior belongs in `MacUtilsCore`, macOS adapters in `MacUtilsSystem`, and composition/presentation in `MacUtilsApp`.

### Change requirements

- Reuse `UtilityAction`, `StateProvider`, the scenario builder, and shared controls before adding a bespoke path.
- Add tests that distinguish the required behavior from a superficially similar wrong implementation.
- Update both English and Russian localization catalogs and documentation when user-visible behavior changes.
- Keep the [landing source](website/README.md), both landing languages, real screenshots, and affected App Store metadata synchronized with every shipped feature change.
- Keep the safe DSL data-only.
- Make hardware tests reversible and record the observed starting and restored states.
- Do not add migration code before the first release unless the schema actually ships and requires it.

### Verification

Run the smallest relevant tests while developing, then before opening a pull request run:

```sh
./scripts/test.sh
./scripts/generate-xcode-project.sh
xcodebuild test -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
xcodebuild analyze -project MacUtils.xcodeproj -scheme MacUtils-Direct -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Explain any environment-only check that cannot run. Do not call a partially passing suite successful.

`MacUtils-UI` activates the application and takes keyboard focus. Run that scheme only in a dedicated macOS login session, virtual machine, or CI runner where it cannot interrupt a person. A BetterDisplay virtual screen can hide windows, but it does not isolate global keyboard focus.

Release operators must follow [Release operations](docs/RELEASING.md). Credentials belong only in protected GitHub Environment Secrets; pull-request jobs never receive signing or App Store credentials.

### Pull requests

Keep commits logical and messages factual. A pull request should explain behavior, risk, verification, UI/localization impact, and screenshots when presentation changes. Accept the [Code of Conduct](CODE_OF_CONDUCT.md).

## Русский

Спасибо за помощь Mac Utils. Изменения должны быть сфокусированными, проверяемыми и соответствовать архитектуре реестров.

Перед большой правкой UI, архитектуры, entitlements или распространения создайте предложение. Прочитайте [Архитектуру](docs/ARCHITECTURE.ru.md), [Расширение Mac Utils](docs/EXTENDING.ru.md) и [Политику безопасности](SECURITY.md). Не публикуйте конфигурацию, сертификаты, профили, токены или пользовательские данные.

Для разработки нужны macOS 26+, Xcode 26, Swift 6.2 и XcodeGen 2.46.0+. Работайте в feature-ветке. Доменные механизмы относятся к `MacUtilsCore`, адаптеры macOS — к `MacUtilsSystem`, композиция и представление — к `MacUtilsApp`.

Переиспользуйте `UtilityAction`, `StateProvider`, конструктор сценариев и общие controls. Добавляйте тесты, обновляйте оба каталога локализации и EN/RU документацию. При каждом изменении выпускаемой функции синхронно обновляйте [лендинг](website/README.md), оба языка, реальные скриншоты и затронутые метаданные App Store. DSL должен оставаться данными без произвольного выполнения. Hardware-проверки обязаны быть обратимыми.

Перед pull request выполните команды из раздела **Verification**. В описании укажите поведение, риски, точные проверки, влияние на UI/локализацию и screenshots при визуальных изменениях. Схема `MacUtils-UI` активирует приложение и перехватывает клавиатурный фокус, поэтому запускайте её только в отдельной GUI-сессии macOS, виртуальной машине или CI runner. Виртуальный дисплей BetterDisplay скрывает окна, но не изолирует глобальный фокус клавиатуры.

Операторы релиза следуют документу [Выпуск релизов](docs/RELEASING.ru.md). Credentials хранятся только в защищённых GitHub Environment Secrets; jobs pull request никогда их не получают.
