# Contributing

## Getting Started

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Write tests first (TDD)
4. Implement the feature
5. Ensure tests pass: `bundle exec rspec`
6. Ensure code quality: `bundle exec rubocop`
7. Commit with conventional format: `feat: add new scanner`
8. Push and open a PR

## Code Standards

- 90% test coverage minimum (SimpleCov)
- RuboCop compliance
- Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- UUID primary keys on all models
- Services follow Single Responsibility Principle

## PR Requirements

- All tests pass
- No RuboCop violations
- Coverage >= 90%
- Description explains what and why
- Linked to a GitHub issue

## Adding a New Scanner

1. Create `app/services/scanners/your_scanner.rb` extending `ScannerBase`
2. Create `app/services/result_parsers/your_parser.rb`
3. Add tool config to scan profile YAMLs
4. Register in `ScanOrchestrator`
5. Add specs with fixture data

## Reporting Security Issues

Please report security vulnerabilities privately via GitHub Security Advisories.
