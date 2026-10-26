# frozen_string_literal: true

module Bus
  # The grammar environment token the scanner puts on its data-plane subjects (#1243).
  #
  # Mirrors the orchestrator's Orchestrator.GrammarEnv (lib/orchestrator/grammar_env.ex)
  # exactly, because both ends must derive the same subject or no message arrives:
  #   production                -> nil      (the unmarked subjects)
  #   staging                   -> "staging"
  #   development, dev, test    -> "dev"
  #   anything else             -> "dev", with a warning
  # Only an exact "production" reaches the unmarked production subjects, so a
  # misspelled or unset environment can never publish into production.
  #
  # The deploy environment is Penetrator.env (APP_ENV); the worker preflight
  # refuses to start without it, since the default ("development") would put a
  # production worker on the dev subject.
  module GrammarEnv
    module_function

    TOKENS = { 'production' => nil, 'staging' => 'staging',
               'development' => 'dev', 'dev' => 'dev', 'test' => 'dev' }.freeze

    # The bus account the transport is connected to (a library argument, validated
    # against production/staging/dev). Derived from the same token, so the account
    # and the subjects can never disagree about the environment.
    def account(env = Penetrator.env)
      token(env) || 'production'
    end

    def token(env = Penetrator.env)
      return TOKENS.fetch(env) if TOKENS.key?(env)

      Penetrator.logger.warn(
        "[GrammarEnv] unknown deploy env #{env.inspect} — scoping subjects to \"dev\" " \
        '(only an exact "production" reaches the unmarked production subjects)'
      )
      'dev'
    end
  end
end
