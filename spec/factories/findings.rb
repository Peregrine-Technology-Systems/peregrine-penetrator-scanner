FactoryBot.define do
  factory :finding do
    association :scan, strategy: :create
    source_tool { %w[zap nuclei sqlmap ffuf nikto].sample }
    severity { %w[critical high medium low info].sample }
    title { Faker::Hacker.say_something_smart }
    url { Faker::Internet.url }
    cwe_id { "CWE-#{rand(1..1000)}" }
    evidence { { 'description' => Faker::Lorem.sentence }.to_json }
    fingerprint { SecureRandom.hex(32) }
    duplicate { false }
  end
end
