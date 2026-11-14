require "rails_helper"

RSpec.describe "config.x.google_oauth" do
  let(:initializer) { Rails.root.join("config/initializers/google_oauth.rb") }

  # Runs the initializer again with GOOGLE_REDIRECT_URI set, and puts the booted configuration back afterwards.
  def configuration_for(redirect_uri)
    booted = Rails.configuration.x.google_oauth
    original = ENV["GOOGLE_REDIRECT_URI"]
    ENV["GOOGLE_REDIRECT_URI"] = redirect_uri
    load initializer
    Rails.configuration.x.google_oauth
  ensure
    ENV["GOOGLE_REDIRECT_URI"] = original
    Rails.configuration.x.google_oauth = booted
  end

  it "derives the YouTube callback from GOOGLE_REDIRECT_URI's host, with a fixed path" do
    expect(Rails.configuration.x.google_oauth[:youtube_redirect_uri])
      .to eq("http://www.example.com/api/v1/youtube_connection/callback")
  end

  it "keeps the scheme and port and replaces the whole path" do
    config = configuration_for("http://localhost:3007/api/v1/google_calendar_connection/callback?ignored=1")

    expect(config[:youtube_redirect_uri]).to eq("http://localhost:3007/api/v1/youtube_connection/callback")
  end

  it "leaves the Calendar's redirect URI as configured" do
    config = configuration_for("https://api.example.com/api/v1/google_calendar_connection/callback")

    expect(config[:redirect_uri]).to eq("https://api.example.com/api/v1/google_calendar_connection/callback")
    expect(config[:youtube_redirect_uri]).to eq("https://api.example.com/api/v1/youtube_connection/callback")
  end
end
