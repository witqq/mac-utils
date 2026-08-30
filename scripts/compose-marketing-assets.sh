#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
background="$repo_root/Assets/Brand/backgrounds/ambient-displays.png"
icon="$repo_root/Sources/MacUtilsApp/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png"
font_regular="/System/Library/Fonts/SFNS.ttf"
font_bold="/System/Library/Fonts/SFNSRounded.ttf"

command -v magick >/dev/null || { print -u2 "ImageMagick is required (brew install imagemagick)."; exit 1; }

compose_screenshot() {
  local locale="$1"
  local name="$2"
  local title="$3"
  local subtitle="$4"
  local raw="$repo_root/Assets/Screenshots/raw/$locale/$name.png"
  local output="$repo_root/Assets/Screenshots/app-store/$locale/$name.png"
  [[ -s "$raw" ]] || { print -u2 "Missing real UI capture: $raw"; exit 1; }

  magick "$background" \
    -resize '2880x1800^' -gravity center -extent 2880x1800 \
    -fill '#05091399' -colorize 35% \
    \( "$raw" -resize '2000x1440' -bordercolor '#FFFFFF22' -border 2 \
       \( +clone -background '#00000080' -shadow 70x28+0+26 \) +swap -background none -layers merge +repage \) \
    -gravity south -geometry +0-40 -composite \
    -font "$font_bold" -fill white -pointsize 92 -gravity north -annotate +0+105 "$title" \
    -font "$font_regular" -fill '#C7D5E8' -pointsize 42 -gravity north -annotate +0+225 "$subtitle" \
    -alpha off -strip "$output"
}

compose_screenshot en 01-builder "Build display workflows visually" "Add actions and state-based branches with the mouse."
compose_screenshot en 02-shortcuts "One shortcut. Any workflow." "Assign and safely edit global keyboard shortcuts."
compose_screenshot en 03-help "Learn every feature in the app" "Built-in guidance for display modes and universal toggles."
compose_screenshot en 04-onboarding "Ready in minutes" "Choose a language and create your first workflow."
compose_screenshot en 05-general "Ready when you sign in" "Control automatic launch and see the live macOS status."

compose_screenshot ru 01-builder "Собирайте сценарии мышкой" "Добавляйте действия и ветвления по состоянию дисплея."
compose_screenshot ru 02-shortcuts "Одна клавиша. Любой сценарий." "Назначайте и безопасно изменяйте глобальные сочетания."
compose_screenshot ru 03-help "Все функции понятны сразу" "Встроенная справка о режимах дисплея и переключателях."
compose_screenshot ru 04-onboarding "Начните за несколько минут" "Выберите язык и создайте первый сценарий."
compose_screenshot ru 05-general "Готово после входа" "Управляйте автозапуском и проверяйте состояние macOS."

mkdir -p "$repo_root/website/assets" "$repo_root/Assets/Brand/social" "$repo_root/Assets/Brand/dmg"
magick "$background" -resize '1280x640^' -gravity center -extent 1280x640 \
  -fill '#05091388' -colorize 32% \
  \( "$icon" -resize 250x250 \) -gravity east -geometry +105+0 -composite \
  -font "$font_bold" -fill white -pointsize 72 -gravity northwest -annotate +90+195 "Mac Utils" \
  -font "$font_regular" -fill '#C7D5E8' -pointsize 32 -gravity northwest \
  -annotate +94+300 "Display workflows. One shortcut." -alpha off -strip \
  "$repo_root/Assets/Brand/social/github-social-preview.png"

magick "$background" -resize '1200x630^' -gravity center -extent 1200x630 \
  -fill '#05091388' -colorize 32% \
  \( "$icon" -resize 230x230 \) -gravity east -geometry +95+0 -composite \
  -font "$font_bold" -fill white -pointsize 68 -gravity northwest -annotate +84+190 "Mac Utils" \
  -font "$font_regular" -fill '#C7D5E8' -pointsize 30 -gravity northwest \
  -annotate +88+286 "Display workflows. One shortcut." -alpha off -strip \
  "$repo_root/website/assets/og-image.png"

magick "$background" -resize '720x480^' -gravity center -extent 720x480 \
  -fill '#05091399' -colorize 38% \
  -font "$font_bold" -fill white -pointsize 36 -gravity north -annotate +0+45 "Mac Utils" \
  -font "$font_regular" -fill '#C7D5E8' -pointsize 18 -gravity north \
  -annotate +0+100 "Drag to Applications" -alpha off -strip \
  "$repo_root/Assets/Brand/dmg/background.png"

magick "$background" -resize '1920x960^' -gravity center -extent 1920x960 \
  -quality 82 "$repo_root/website/assets/hero-background.webp"
magick "$icon" -resize 256x256 "$repo_root/website/assets/app-icon.png"
for locale in en ru; do
  magick "$repo_root/Assets/Screenshots/raw/$locale/01-builder.png" -resize '1600x1152>' \
    -quality 84 "$repo_root/website/assets/builder-$locale.webp"
  magick "$repo_root/Assets/Screenshots/raw/$locale/02-shortcuts.png" -resize '1600x1152>' \
    -quality 84 "$repo_root/website/assets/shortcuts-$locale.webp"
done

print "Composed 10 App Store screenshots, social/DMG assets, and optimized landing images."
