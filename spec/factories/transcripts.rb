FactoryBot.define do
  factory :transcript do
    video
    started_at { Time.current }

    trait :done do
      outcome { "done" }
      lines { [ { "text" => "Hello there", "start" => 0.0 }, { "text" => "General", "start" => 1.5 } ] }
      finished_at { Time.current }
    end

    trait :no_captions do
      outcome { "no_captions" }
      finished_at { Time.current }
    end

    trait :failed do
      outcome { "failed" }
      reason { "blocked" }
      finished_at { Time.current }
    end

    # A fetch that began long ago and never finished.
    trait :expired do
      started_at { (Transcript::LEASE + 1.minute).ago }
    end
  end
end
