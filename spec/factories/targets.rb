FactoryBot.define do
  factory :target do
    name { Faker::Company.name }
    urls { ["https://#{Faker::Internet.domain_name}"].to_json }
    auth_type { 'none' }
    active { true }
  end
end
