FactoryBot.define do
  factory :scan do
    association :target, strategy: :create
    profile { 'standard' }
    status { 'pending' }

    trait :running do
      status { 'running' }
      started_at { Time.current }
    end

    trait :completed do
      status { 'completed' }
      started_at { 30.minutes.ago }
      completed_at { Time.current }
      summary { { 'total_findings' => 5, 'by_severity' => { 'high' => 2, 'medium' => 3 } }.to_json }
    end
  end
end
