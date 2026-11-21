require "rails_helper"

RSpec.describe WorldnamerTelemetry::RootDatabaseSpanSampler, type: :lib do
  def db_spans
    captured_spans.select { |span| span.attributes&.key?("db.system") }
  end

  it "drops database spans that start a trace, as Solid Queue's polling does" do
    ActiveRecord::Base.connection.select_value("SELECT 1")

    expect(db_spans).to be_empty
  end

  it "keeps database spans that run under another span, as in a request or a job" do
    WorldnamerTelemetry.tracer.in_span("perform") do
      ActiveRecord::Base.connection.select_value("SELECT 1")
    end

    expect(captured_spans.map(&:name)).to include("perform")
    expect(db_spans).not_to be_empty
  end

  it "keeps non-database spans that start a trace, such as a job's perform span" do
    WorldnamerTelemetry.tracer.in_span("perform") { nil }

    expect(captured_spans.map(&:name)).to eq([ "perform" ])
  end
end
