FactoryBot.define do
  factory :report do
    scan
    format { 'json' }
    status { 'pending' }
  end
end
