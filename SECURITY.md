# Security policy

## Supported versions

The latest published major version will receive security fixes. Mac Utils v1.0.0 has not been published yet, so there is currently no supported public binary. Reports against the `main` development branch are still welcome.

## Report a vulnerability privately

Do not open a public issue and do not include exploit details, credentials, signing materials, private configuration, or personal data in discussions.

Use [GitHub private vulnerability reporting](https://github.com/witqq/mac-utils/security/advisories/new). If that form is temporarily unavailable, contact the repository owner through GitHub without disclosing vulnerability details publicly.

Include only the information needed to reproduce and assess the problem:

- affected commit, version, and build;
- macOS version and hardware class;
- security impact and preconditions;
- minimal reproduction steps or proof of concept;
- whether App Store sandbox or direct distribution is affected;
- suggested remediation, if known.

You should receive an acknowledgement through the private advisory. Remediation and disclosure timing depend on severity, reproducibility, Apple platform behavior, and release-signing availability. Please allow a coordinated fix before public disclosure.

## Security boundaries

High-impact areas include:

- bypassing the action/state registries to execute arbitrary code;
- parser input that launches processes or accesses files;
- unsafe CoreGraphics display transactions that leave a partial configuration;
- global hotkey replacement that drops the previous working assignment on failure;
- configuration writes that expose, corrupt, or silently discard user data;
- entitlement, signing, notarization, release-workflow, or dependency compromise.

Mac Utils does not treat a display UUID as an authentication secret. Configuration files can still reveal user-created names and hardware topology and should not be posted publicly by default.

## Repository secrets

Never commit Apple certificates, private keys, provisioning profiles, App Store Connect API private keys, notarization credentials, or GitHub tokens. Release credentials belong only in the protected local keychain or GitHub Environment/Secrets configured for distribution.

---

# Политика безопасности

## Поддерживаемые версии

Исправления безопасности получает последняя опубликованная основная версия. Mac Utils v1.0.0 ещё не опубликована, поэтому поддерживаемого публичного бинарника пока нет. Сообщения о ветке разработки `main` принимаются.

## Приватное сообщение об уязвимости

Не создавайте публичный issue и не публикуйте exploit, credentials, материалы подписи, конфигурацию или персональные данные.

Используйте [приватные GitHub Security Advisories](https://github.com/witqq/mac-utils/security/advisories/new). Если форма временно недоступна, свяжитесь с владельцем репозитория через GitHub, не раскрывая детали уязвимости публично.

Укажите только необходимые данные: commit/версию/build, версию macOS, влияние и условия атаки, минимальные шаги, затронутый канал App Store/direct и возможное исправление. Ответ придёт через приватный advisory. Срок исправления и раскрытия зависит от серьёзности, воспроизводимости, поведения платформы Apple и доступности релизной подписи.

Не коммитьте сертификаты Apple, приватные ключи, provisioning profiles, App Store Connect API keys, credentials notarization или GitHub tokens. Релизные секреты хранятся только в защищённом keychain или GitHub Environment/Secrets.
