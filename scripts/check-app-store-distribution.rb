#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../fastlane/app_store_distribution"

class FakeDistribution < AppStoreDistribution
  attr_reader :requests

  def initialize(existing_price_schedule: false)
    super(token: Object.new, api_root: "https://example.test")
    @requests = []
    @availability_created = false
    @schedule_state = existing_price_schedule ? :paid : :missing
    @territory_reads = 0
  end

  private

  def request(request_class, request_uri, body = nil)
    @requests << [request_class.name, request_uri.path, body]
    case [request_class.name, request_uri.path]
    when ["Net::HTTP::Get", "/v1/territories"]
      collection([{ "type" => "territories", "id" => "USA" }, { "type" => "territories", "id" => "CAN" }])
    when ["Net::HTTP::Get", "/v1/apps/app-id/appAvailabilityV2"]
      raise APIError.new(404, "errors" => []) unless @availability_created

      { "data" => { "type" => "appAvailabilities", "id" => "availability-id", "attributes" => { "availableInNewTerritories" => true } } }
    when ["Net::HTTP::Post", "/v2/appAvailabilities"]
      @availability_created = true
      { "data" => { "type" => "appAvailabilities", "id" => "availability-id" } }
    when ["Net::HTTP::Get", "/v2/appAvailabilities/availability-id/territoryAvailabilities"]
      @territory_reads += 1
      collection([
        territory_availability("availability-usa", "USA", true),
        territory_availability("availability-can", "CAN", @territory_reads > 1)
      ])
    when ["Net::HTTP::Patch", "/v1/territoryAvailabilities/availability-can"]
      { "data" => body.fetch(:data) }
    when ["Net::HTTP::Get", "/v1/apps/app-id/appPriceSchedule"]
      raise APIError.new(404, "errors" => []) if @schedule_state == :missing

      { "data" => { "type" => "appPriceSchedules", "id" => "schedule-id" } }
    when ["Net::HTTP::Get", "/v1/apps/app-id/appPricePoints"]
      collection([{ "type" => "appPricePoints", "id" => "free-point", "attributes" => { "customerPrice" => "0.00" } }])
    when ["Net::HTTP::Post", "/v1/appPriceSchedules"]
      @schedule_state = :free
      { "data" => { "type" => "appPriceSchedules", "id" => "schedule-id" } }
    when ["Net::HTTP::Get", "/v1/appPriceSchedules/schedule-id/manualPrices"]
      price_point_id = @schedule_state == :free ? "free-point" : "paid-point"
      customer_price = @schedule_state == :free ? "0.00" : "4.99"
      {
        "data" => [
          {
            "type" => "appPrices",
            "id" => "active-price",
            "attributes" => { "startDate" => nil, "endDate" => nil },
            "relationships" => { "appPricePoint" => { "data" => { "type" => "appPricePoints", "id" => price_point_id } } }
          }
        ],
        "included" => [{ "type" => "appPricePoints", "id" => price_point_id, "attributes" => { "customerPrice" => customer_price } }]
      }
    else
      raise "Unexpected request #{request_class.name} #{request_uri}"
    end
  end

  def collection(data)
    { "data" => data, "links" => { "next" => nil } }
  end

  def territory_availability(id, territory_id, available)
    {
      "type" => "territoryAvailabilities",
      "id" => id,
      "attributes" => { "available" => available },
      "relationships" => { "territory" => { "data" => { "type" => "territories", "id" => territory_id } } }
    }
  end
end

distribution = FakeDistribution.new
distribution.ensure_free_and_worldwide!("app-id")

availability_create = distribution.requests.find { |method, path, _| method == "Net::HTTP::Post" && path == "/v2/appAvailabilities" }
raise "Worldwide availability was not created" unless availability_create
availability_payload = availability_create.fetch(2)
raise "New territories must be enabled" unless availability_payload.dig(:data, :attributes, :availableInNewTerritories) == true
raise "Both territories must be included" unless availability_payload.fetch(:included).length == 2

availability_patch = distribution.requests.find { |method, path, _| method == "Net::HTTP::Patch" && path.end_with?("availability-can") }
raise "Unavailable territory was not enabled" unless availability_patch&.dig(2, :data, :attributes, :available) == true

price_create = distribution.requests.find { |method, path, _| method == "Net::HTTP::Post" && path == "/v1/appPriceSchedules" }
raise "Free price schedule was not created" unless price_create
price_payload = price_create.fetch(2)
raise "Free price point was not selected" unless price_payload.dig(:included, 0, :relationships, :appPricePoint, :data, :id) == "free-point"

puts "Modern App Store distribution client valid: free price, all territories, and post-write verification."

existing_schedule = FakeDistribution.new(existing_price_schedule: true)
existing_schedule.ensure_free_and_worldwide!("app-id")
price_change = existing_schedule.requests.find { |method, path, _| method == "Net::HTTP::Post" && path == "/v1/appPriceSchedules" }
raise "Existing paid schedule was not changed" unless price_change
raise "Existing schedule change must start today" unless price_change.dig(2, :included, 0, :attributes, :startDate) == Date.today.iso8601

puts "Existing paid App Store schedule valid: immediate free price change and active-price verification."
