#!/bin/zsh
set -euo pipefail

# Builds the bilingual landing from website/source with the pinned agentic-report release into
# website/dist (committed generated output) and adds the page identity that the generator does not
# own: favicon, canonical URL, social preview, and theme color.

cd "${0:A:h}/.."

release="0.14.0"
source_dir="website/source"
dist_dir="website/dist"
site_url="https://mac-utils.witqq.dev/"

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
  site = ARGV.fetch(1)
  html = File.read(path, encoding: "UTF-8")
  head = <<~HEAD.strip
    <link rel="canonical" href="#{site}"/>
    <link rel="icon" href="assets/app-icon.png"/>
    <meta name="theme-color" content="#0b1020"/>
    <meta property="og:type" content="website"/>
    <meta property="og:title" content="Mac Utils"/>
    <meta property="og:description" content="One key runs your whole script. Build scripts from ready-made macOS actions and run them with a global shortcut."/>
    <meta property="og:url" content="#{site}"/>
    <meta property="og:image" content="#{site}assets/og-image.png"/>
    <meta name="twitter:card" content="summary_large_image"/>
  HEAD
  abort "No </head> in #{path}" unless html.include?("</head>")
  File.write(path, html.sub("</head>", "#{head}\n</head>"))
' "$dist_dir/index.html" "$site_url"

print "Landing ready in $dist_dir"
