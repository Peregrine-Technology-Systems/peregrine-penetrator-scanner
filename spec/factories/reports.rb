FactoryBot.define do
  factory :report do
    association :scan, strategy: :create
    format { 'json' }
    status { 'pending' }
  end
end
