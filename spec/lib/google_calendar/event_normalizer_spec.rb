require "rails_helper"

RSpec.describe GoogleCalendar::EventNormalizer do
  def timed(id: "def", summary: "Dentist", start: "2026-11-01T09:00:00-06:00", finish: "2026-11-01T10:00:00-07:00", **extra)
    { "id" => id, "status" => "confirmed", "summary" => summary, "eventType" => "default",
      "start" => { "dateTime" => start, "timeZone" => "America/Denver" },
      "end" => { "dateTime" => finish, "timeZone" => "America/Denver" } }.merge(extra.transform_keys(&:to_s))
  end

  def all_day(id: "abc", summary: "Holiday", start: "2026-11-01", finish: "2026-11-02", **extra)
    { "id" => id, "status" => "confirmed", "summary" => summary, "eventType" => "default",
      "start" => { "date" => start }, "end" => { "date" => finish } }.merge(extra.transform_keys(&:to_s))
  end

  def normalize(*items)
    described_class.call(items)
  end

  it "turns a timed event into a row with its start and end as given, offsets included" do
    expect(normalize(timed)).to eq([
      { id: "def", title: "Dentist", all_day: false, starts_on: nil, ends_on: nil,
        starts_at: "2026-11-01T09:00:00-06:00", ends_at: "2026-11-01T10:00:00-07:00" }
    ])
  end

  it "keeps a UTC time in UTC and drops fractional seconds" do
    row = normalize(timed(start: "2026-11-01T15:00:00Z", finish: "2026-11-01T16:00:00.500Z")).first

    expect(row[:starts_at]).to eq("2026-11-01T15:00:00Z")
    expect(row[:ends_at]).to eq("2026-11-01T16:00:00Z")
  end

  it "turns an all-day event into a row with its dates, the end date exclusive" do
    expect(normalize(all_day)).to eq([
      { id: "abc", title: "Holiday", all_day: true, starts_on: Date.new(2026, 11, 1), ends_on: Date.new(2026, 11, 2),
        starts_at: nil, ends_at: nil }
    ])
  end

  it "gives a null title for a missing or blank summary" do
    rows = normalize(timed(id: "a", summary: nil).except("summary"), timed(id: "b", summary: ""), timed(id: "c", summary: "  "))

    expect(rows.map { |row| row[:title] }).to eq([ nil, nil, nil ])
  end

  it "passes on only the contract fields, whatever else Google sent" do
    item = timed.merge("description" => "Leaky description", "location" => "Leaky street",
      "attendees" => [ { "self" => true, "responseStatus" => "accepted", "email" => "leaky@example.com" } ],
      "hangoutLink" => "https://meet.example/leaky")

    row = normalize(item).first

    expect(row.keys).to eq(%i[id title all_day starts_on ends_on starts_at ends_at])
    expect(row.inspect).not_to include("Leaky", "leaky")
  end

  it "drops cancelled events" do
    expect(normalize(timed(status: "cancelled"), all_day(status: "cancelled"))).to eq([])
  end

  it "drops invitations the user declined, and keeps ones they accepted, have not answered or only others declined" do
    declined = timed(id: "declined", attendees: [ { "self" => true, "responseStatus" => "declined" } ])
    accepted = timed(id: "accepted", attendees: [ { "self" => true, "responseStatus" => "accepted" } ])
    pending = timed(id: "pending", attendees: [ { "self" => true, "responseStatus" => "needsAction" } ])
    others = timed(id: "others", attendees: [ { "responseStatus" => "declined" }, { "self" => true, "responseStatus" => "tentative" } ])

    expect(normalize(declined, accepted, pending, others).map { |row| row[:id] }).to eq(%w[accepted pending others])
  end

  it "drops working-location entries and keeps birthdays, out-of-office and focus time" do
    rows = normalize(
      all_day(id: "home", eventType: "workingLocation"),
      all_day(id: "birthday", eventType: "birthday"),
      timed(id: "ooo", eventType: "outOfOffice"),
      timed(id: "focus", eventType: "focusTime")
    )

    expect(rows.map { |row| row[:id] }).to eq(%w[birthday ooo focus])
  end

  it "keeps an event with no eventType" do
    expect(normalize(timed.except("eventType")).size).to eq(1)
  end

  it "is empty for no items, and when every item was filtered out" do
    expect(normalize).to eq([])
    expect(normalize(timed(status: "cancelled"), all_day(eventType: "workingLocation"))).to eq([])
  end

  it "keeps Google's order and does not pick a day" do
    rows = normalize(
      timed(id: "later", start: "2026-11-02T09:00:00Z", finish: "2026-11-02T10:00:00Z"),
      timed(id: "earlier", start: "2026-10-31T09:00:00Z", finish: "2026-10-31T10:00:00Z")
    )

    expect(rows.map { |row| row[:id] }).to eq(%w[later earlier])
  end

  it "leaves out items it cannot place: no id, no start, unreadable or offset-less times, bad dates" do
    rows = normalize(
      timed(id: nil),
      timed.except("start"),
      timed(start: "tomorrow at nine"),
      timed(start: "2026-11-01T09:00:00"),
      timed(finish: nil),
      all_day(start: "2026-02-30"),
      all_day(finish: "20261102"),
      "not an event"
    )

    expect(rows).to eq([])
  end
end
