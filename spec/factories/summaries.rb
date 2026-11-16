FactoryBot.define do
  factory :summary do
    video
    started_at { Time.current }

    trait :done do
      outcome { "done" }
      summary_text { "A short summary of the video." }
      model { "spec-model" }
      finished_at { Time.current }
    end

    trait :nothing_to_summarise do
      outcome { "nothing_to_summarise" }
      finished_at { Time.current }
    end

    trait :failed do
      outcome { "failed" }
      reason { "timed_out" }
      finished_at { Time.current }
    end

    # A summary that began long ago and never finished.
    trait :expired do
      started_at { (Summary::LEASE + 1.minute).ago }
    end
  end
end
