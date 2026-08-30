require "bigdecimal"
require "date"
require "json"
require "net/http"
require "uri"

class AppStoreDistribution
  API_ROOT = "https://api.appstoreconnect.apple.com"
  BASE_TERRITORY = "USA"

  class APIError < StandardError
    attr_reader :status

    def initialize(status, body)
      @status = status
      details = Array(body["errors"]).map do |error|
        [error["code"], error["title"], error["detail"]].compact.join(": ")
      end
      super("App Store Connect API returned HTTP #{status}: #{details.join(" | ")}")
    end
  end

  def initialize(token:, api_root: API_ROOT)
    @token = token
    @api_root = api_root
  end

  def ensure_free_and_worldwide!(app_id)
    territory_ids = all_pages("/v1/territories", limit: 200).map { |territory| territory.fetch("id") }
    raise "App Store Connect returned no territories" if territory_ids.empty?

    ensure_worldwide!(app_id, territory_ids)
    ensure_free!(app_id)
  end

  private

  def ensure_worldwide!(app_id, territory_ids)
    availability = optional_get("/v1/apps/#{app_id}/appAvailabilityV2")
    unless availability
      create_worldwide_availability(app_id, territory_ids)
      availability = get("/v1/apps/#{app_id}/appAvailabilityV2")
    end

    availability_data = availability.fetch("data")
    availability_id = availability_data.fetch("id")
    unless availability_data.dig("attributes", "availableInNewTerritories") == true
      raise "App availability does not automatically include new territories; enable it in App Store Connect"
    end

    records = all_pages(
      "/v2/appAvailabilities/#{availability_id}/territoryAvailabilities",
      include: "territory",
      limit: 200
    )
    records_by_territory = records.to_h do |record|
      [record.dig("relationships", "territory", "data", "id"), record]
    end
    missing = territory_ids - records_by_territory.keys
    raise "App availability is missing territories: #{missing.join(", ")}" unless missing.empty?

    records_by_territory.each_value do |record|
      next if record.dig("attributes", "available") == true

      patch(
        "/v1/territoryAvailabilities/#{record.fetch("id")}",
        data: {
          type: "territoryAvailabilities",
          id: record.fetch("id"),
          attributes: { available: true }
        }
      )
    end

    refreshed = all_pages(
      "/v2/appAvailabilities/#{availability_id}/territoryAvailabilities",
      include: "territory",
      limit: 200
    )
    unavailable = refreshed.each_with_object([]) do |record, result|
      result << record.dig("relationships", "territory", "data", "id") unless record.dig("attributes", "available") == true
    end
    raise "App remains unavailable in territories: #{unavailable.join(", ")}" unless unavailable.empty?
  end

  def create_worldwide_availability(app_id, territory_ids)
    linkages = []
    included = territory_ids.each_with_index.map do |territory_id, index|
      temporary_id = "${territory-#{index}}"
      linkages << { type: "territoryAvailabilities", id: temporary_id }
      {
        type: "territoryAvailabilities",
        id: temporary_id,
        attributes: { available: true },
        relationships: {
          territory: { data: { type: "territories", id: territory_id } }
        }
      }
    end

    post(
      "/v2/appAvailabilities",
      data: {
        type: "appAvailabilities",
        attributes: { availableInNewTerritories: true },
        relationships: {
          app: { data: { type: "apps", id: app_id } },
          territoryAvailabilities: { data: linkages }
        }
      },
      included: included
    )
  end

  def ensure_free!(app_id)
    schedule = optional_get("/v1/apps/#{app_id}/appPriceSchedule")
    return if schedule && schedule_is_free?(schedule.fetch("data").fetch("id"))

    price_points = all_pages(
      "/v1/apps/#{app_id}/appPricePoints",
      "filter[territory]": BASE_TERRITORY,
      "fields[appPricePoints]": "customerPrice,territory",
      limit: 200
    )
    free_point = price_points.find { |point| zero_price?(point) }
    raise "App Store Connect returned no free price point for #{BASE_TERRITORY}" unless free_point

    schedule_price_change(app_id, free_point.fetch("id"), starts_today: !schedule.nil?)
    updated_schedule = get("/v1/apps/#{app_id}/appPriceSchedule")
    raise "App Store price schedule was updated but its active price is not free" unless schedule_is_free?(updated_schedule.fetch("data").fetch("id"))
  end

  def schedule_price_change(app_id, price_point_id, starts_today:)
    temporary_id = "${price-0}"
    post(
      "/v1/appPriceSchedules",
      data: {
        type: "appPriceSchedules",
        relationships: {
          app: { data: { type: "apps", id: app_id } },
          baseTerritory: { data: { type: "territories", id: BASE_TERRITORY } },
          manualPrices: { data: [{ type: "appPrices", id: temporary_id }] }
        }
      },
      included: [
        {
          type: "appPrices",
          id: temporary_id,
          attributes: { startDate: starts_today ? Date.today.iso8601 : nil, endDate: nil },
          relationships: {
            appPricePoint: { data: { type: "appPricePoints", id: price_point_id } }
          }
        }
      ]
    )

  end

  def schedule_is_free?(schedule_id)
    response = get(
      "/v1/appPriceSchedules/#{schedule_id}/manualPrices",
      include: "appPricePoint,territory",
      "fields[appPricePoints]": "customerPrice,territory",
      limit: 200
    )
    price_points = Array(response["included"])
      .select { |record| record["type"] == "appPricePoints" }
      .to_h { |record| [record.fetch("id"), record] }
    today = Date.today
    Array(response["data"]).any? do |price|
      start_date = parse_date(price.dig("attributes", "startDate"))
      end_date = parse_date(price.dig("attributes", "endDate"))
      active = (start_date.nil? || start_date <= today) && (end_date.nil? || end_date >= today)
      price_point_id = price.dig("relationships", "appPricePoint", "data", "id")
      active && zero_price?(price_points[price_point_id] || {})
    end
  end

  def parse_date(value)
    Date.iso8601(value) unless value.to_s.empty?
  rescue Date::Error
    nil
  end

  def zero_price?(record)
    value = record.dig("attributes", "customerPrice").to_s
    !value.empty? && BigDecimal(value).zero?
  rescue ArgumentError
    false
  end

  def all_pages(path, query = {})
    response = get(path, query)
    records = Array(response["data"])
    while (next_url = response.dig("links", "next"))
      response = request(Net::HTTP::Get, URI(next_url))
      records.concat(Array(response["data"]))
    end
    records
  end

  def optional_get(path, query = {})
    get(path, query)
  rescue APIError => error
    raise unless error.status == 404

    nil
  end

  def get(path, query = {})
    request(Net::HTTP::Get, uri(path, query))
  end

  def post(path, body)
    request(Net::HTTP::Post, uri(path), body)
  end

  def patch(path, body)
    request(Net::HTTP::Patch, uri(path), body)
  end

  def uri(path, query = {})
    result = URI.join(@api_root, path)
    result.query = URI.encode_www_form(query) unless query.empty?
    result
  end

  def request(request_class, request_uri, body = nil)
    @token.refresh! if @token.expired?
    request = request_class.new(request_uri)
    request["Authorization"] = "Bearer #{@token.text}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body

    response = Net::HTTP.start(
      request_uri.host,
      request_uri.port,
      use_ssl: request_uri.scheme == "https",
      open_timeout: 30,
      read_timeout: 120
    ) { |http| http.request(request) }
    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
    raise APIError.new(response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)

    parsed
  end
end
