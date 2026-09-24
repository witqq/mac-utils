#!/bin/zsh
set -euo pipefail

# Builds the bilingual landing from website/source with the pinned agentic-report release into
# website/dist (committed generated output). The source declares its public URL and social image, so the
# generator writes the canonical link and Open Graph tags; this script adds the favicon and theme color,
# which the generator does not own, and then indexes the tree with robots.txt and sitemap.xml.

cd "${0:A:h}/.."

release="0.17.0"
source_dir="website/source"
dist_dir="website/dist"

rm -rf "$dist_dir"
npx --yes "agentic-report@$release" build "$source_dir" --output "$dist_dir" --format directory --json \
  | ruby -rjson -e '
    result = nil
    STDIN.each_line do |line|
      record = JSON.parse(line) rescue next
      case record["type"]
      when "result" then result = record
      when "diagnostic" then warn "#{record["code"]}: #{record["message"]} (#{record["file"]})"
      end
    end
    abort "agentic-report build produced no result" unless result
    abort "agentic-report build warnings: #{result["warnings"].inspect}" unless result["warnings"].empty?
    puts "Built #{result["outputPath"]} (#{result["format"]}, #{result["externalAssets"]} external assets)"
  '

cp "$source_dir/assets/app-icon.png" "$source_dir/assets/og-image.png" "$dist_dir/assets/"

ruby -e '
  path = ARGV.fetch(0)
  html = File.read(path, encoding: "UTF-8")
  head = <<~HEAD.strip
    <link rel="icon" href="assets/app-icon.png"/>
    <meta name="theme-color" content="#0b1020"/>
  HEAD
  abort "No </head> in #{path}" unless html.include?("</head>")
  File.write(path, html.sub("</head>", "#{head}\n</head>"))
' "$dist_dir/index.html"

# The sitemap is derived from the canonical URL the generator wrote into the page.
npx --yes "agentic-report@$release" sitemap "$dist_dir" --json >/dev/null

print "Landing ready in $dist_dir"
