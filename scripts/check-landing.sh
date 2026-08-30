#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
landing="$repo_root/website/index.html"

for file in index.html styles.css app.js assets/app-icon.png assets/hero-background.webp \
  assets/builder-en.webp assets/builder-ru.webp assets/shortcuts-en.webp assets/shortcuts-ru.webp \
  assets/og-image.png; do
  [[ -s "$repo_root/website/$file" ]] || { print -u2 "Missing landing asset: website/$file"; exit 1; }
done

ruby - "$landing" <<'RUBY'
html = File.read(ARGV.fetch(0), encoding: "UTF-8")
errors = []
ids = html.scan(/\bid="([^"]+)"/).flatten
errors << "Duplicate HTML ids: #{ids.group_by(&:itself).select { |_, values| values.length > 1 }.keys.join(", ")}" unless ids.uniq.length == ids.length
html.scan(/href="#([^"]+)"/).flatten.each { |target| errors << "Missing anchor target ##{target}" unless ids.include?(target) }
errors << "App Store CTA must remain disabled until a product URL exists" unless html.scan(/aria-disabled="true"/).length == 2
errors << "Landing must expose EN and RU controls" unless html.include?('data-language="en"') && html.include?('data-language="ru"')
errors << "Landing contains an insecure external URL" if html.match?(/(?:href|src)="http:\/\//)
errors << "Landing depends on an external runtime asset" if html.match?(/(?:src|href)="https:\/\/(?!github\.com|witqq\.dev|mac-utils\.witqq\.dev)/)
abort errors.join("\n") unless errors.empty?
puts "Landing source valid: unique anchors, bilingual controls, local runtime assets, HTTPS external links, disabled App Store CTAs."
RUBY
