#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "uri"

ROOT = File.expand_path("..", __dir__)
errors = []

def value(path)
  File.read(path, encoding: "UTF-8").strip
end

def image_property(path, property)
  output, status = Open3.capture2e("sips", "-g", property, path)
  raise "sips failed for #{path}: #{output}" unless status.success?

  output.lines.map { |line| line.strip.split(": ", 2)[1] }.compact.last
end

locales = %w[en-US ru]
required_fields = %w[
  name subtitle promotional_text keywords description release_notes
  support_url marketing_url privacy_url
]

locales.each do |locale|
  directory = File.join(ROOT, "AppStore", "metadata", locale)
  required_fields.each do |field|
    path = File.join(directory, "#{field}.txt")
    errors << "Missing #{path}" unless File.file?(path) && !value(path).empty?
  end
  next unless required_fields.all? { |field| File.file?(File.join(directory, "#{field}.txt")) }

  limits = {
    "name" => 30,
    "subtitle" => 30,
    "promotional_text" => 170,
    "description" => 4_000,
  }
  limits.each do |field, limit|
    content = value(File.join(directory, "#{field}.txt"))
    errors << "#{locale}/#{field} is #{content.length} characters (max #{limit})" if content.length > limit
  end
  keywords = value(File.join(directory, "keywords.txt"))
  errors << "#{locale}/keywords is #{keywords.bytesize} UTF-8 bytes (max 100)" if keywords.bytesize > 100
  errors << "#{locale}/keywords contains a duplicate app name" if keywords.downcase.include?("mac utils")

  %w[support_url marketing_url privacy_url].each do |field|
    url = value(File.join(directory, "#{field}.txt"))
    parsed = URI.parse(url)
    errors << "#{locale}/#{field} must be an absolute HTTPS URL" unless parsed.is_a?(URI::HTTPS) && parsed.host
  rescue URI::InvalidURIError
    errors << "#{locale}/#{field} is not a valid URL"
  end
end

json_files = {}
%w[category.json app-privacy.json age-rating.json].each do |name|
  path = File.join(ROOT, "AppStore", name)
  json_files[name] = JSON.parse(File.read(path, encoding: "UTF-8"))
rescue Errno::ENOENT, JSON::ParserError => error
  errors << "Invalid #{path}: #{error.message}"
end

category = json_files["category.json"]
errors << "App Store categories must be Utilities and Productivity" unless category == { "primary" => "Utilities", "secondary" => "Productivity" }

privacy = json_files["app-privacy.json"]
expected_privacy = {
  "dataCollected" => false,
  "tracking" => false,
  "privacyPolicyURL" => "https://mac-utils.witqq.dev/#privacy",
}
errors << "App privacy declaration must state no collection/tracking and use the production privacy URL" unless privacy == expected_privacy

rating = json_files["age-rating.json"]
rating_enum_fields = %w[
  alcoholTobaccoOrDrugUseOrReferences contests gamblingSimulated gunsOrOtherWeapons
  horrorOrFearThemes matureOrSuggestiveThemes medicalOrTreatmentInformation
  profanityOrCrudeHumor sexualContentGraphicAndNudity sexualContentOrNudity
  violenceCartoonOrFantasy violenceRealistic violenceRealisticProlongedGraphicOrSadistic
  ageRatingOverrideV2 koreaAgeRatingOverride
]
rating_boolean_fields = %w[
  socialMedia socialMediaAgeRestricted advertising ageAssurance gambling healthOrWellnessTopics
  lootBox messagingAndChat parentalControls unrestrictedWebAccess userGeneratedContent
]
rating_nullable_fields = %w[kidsAgeBand developerAgeRatingInfoUrl]
expected_rating_fields = rating_enum_fields + rating_boolean_fields + rating_nullable_fields
if rating
  errors << "Age rating fields do not match the Fastlane 2.238.0 declaration" unless rating.keys.sort == expected_rating_fields.sort
  rating_enum_fields.each { |field| errors << "Age rating #{field} must be NONE" unless rating[field] == "NONE" }
  rating_boolean_fields.each { |field| errors << "Age rating #{field} must be false" unless rating[field] == false }
  rating_nullable_fields.each { |field| errors << "Age rating #{field} must be null" unless rating[field].nil? }
end

review_notes = File.join(ROOT, "AppStore", "review-notes.md")
errors << "App Review notes must contain the two-display review path" unless File.file?(review_notes) && value(review_notes).include?("Connect two displays")

copyright = File.join(ROOT, "AppStore", "metadata", "copyright.txt")
errors << "App Store copyright must identify the 2026 rights holder" unless File.file?(copyright) && value(copyright) == "2026 Mikhail Belyi"

gemfile = File.join(ROOT, "Gemfile")
errors << "Gemfile must pin Fastlane 2.238.0" unless File.file?(gemfile) && value(gemfile).include?('gem "fastlane", "2.238.0"')

fastfile = File.join(ROOT, "fastlane", "Fastfile")
errors << "Fastlane API-key precheck must exclude unsupported in-app purchase lookup" unless File.file?(fastfile) && value(fastfile).include?("precheck_include_in_app_purchases: false")

expected_icons = {
  "app-icon-16.png" => 16,
  "app-icon-32.png" => 32,
  "app-icon-64.png" => 64,
  "app-icon-128.png" => 128,
  "app-icon-256.png" => 256,
  "app-icon-512.png" => 512,
  "app-icon-1024.png" => 1_024,
}
icon_root = File.join(ROOT, "Sources", "MacUtilsApp", "Resources", "Assets.xcassets", "AppIcon.appiconset")
expected_icons.each do |name, size|
  path = File.join(icon_root, name)
  if !File.file?(path)
    errors << "Missing AppIcon source #{path}"
    next
  end
  width = image_property(path, "pixelWidth").to_i
  height = image_property(path, "pixelHeight").to_i
  errors << "#{name} is #{width}x#{height}; expected #{size}x#{size}" unless width == size && height == size
end

{ "menu-bar-icon-18.png" => 18, "menu-bar-icon-36.png" => 36 }.each do |name, size|
  path = File.join(ROOT, "Sources", "MacUtilsApp", "Resources", "Assets.xcassets", "MenuBarIcon.imageset", name)
  width = File.file?(path) ? image_property(path, "pixelWidth").to_i : 0
  height = File.file?(path) ? image_property(path, "pixelHeight").to_i : 0
  errors << "#{name} is missing or not #{size}x#{size}" unless width == size && height == size
end

%w[en ru].each do |locale|
  screenshots = Dir[File.join(ROOT, "Assets", "Screenshots", "app-store", locale, "*.png")].sort
  errors << "#{locale} requires 1–10 App Store screenshots; found #{screenshots.length}" unless (1..10).cover?(screenshots.length)
  screenshots.each do |path|
    width = image_property(path, "pixelWidth").to_i
    height = image_property(path, "pixelHeight").to_i
    alpha = image_property(path, "hasAlpha")
    errors << "#{path} is #{width}x#{height}; expected 2880x1800" unless [width, height] == [2_880, 1_800]
    errors << "#{path} has an alpha channel" unless alpha == "no"
  end
end

expected_marketing = {
  File.join(ROOT, "Assets", "Brand", "social", "github-social-preview.png") => [1_280, 640],
  File.join(ROOT, "website", "assets", "og-image.png") => [1_200, 630],
  File.join(ROOT, "Assets", "Brand", "dmg", "background.png") => [720, 480],
}
expected_marketing.each do |path, dimensions|
  actual = File.file?(path) ? [image_property(path, "pixelWidth").to_i, image_property(path, "pixelHeight").to_i] : [0, 0]
  errors << "#{path} is #{actual.join("x")}; expected #{dimensions.join("x")}" unless actual == dimensions
end

if errors.empty?
  puts "Release assets valid: 2 metadata locales, 7 AppIcon PNGs, 2 menu icons, 8 App Store screenshots, 3 marketing images."
else
  warn errors.join("\n")
  exit 1
end
