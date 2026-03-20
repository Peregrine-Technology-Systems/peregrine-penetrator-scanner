FactoryBot.define do
  factory :target do
    name { Faker::Company.name }
    urls { ["https://#{Faker::Internet.domain_name}"].to_json }
    auth_type { 'none' }
    active { true }

    trait :with_github_tickets do
      ticket_tracker { 'github' }
      ticket_config do
        {
          'owner' => 'test-org',
          'repo' => 'test-repo',
          'token_env' => 'GITHUB_TOKEN',
          'min_severity' => 'low',
          'labels' => ['pentest']
        }
      end
    end
  end
end
