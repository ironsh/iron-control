# The Broker namespace holds the in-control port of iron-token-broker: the OAuth
# refresh-token state machine that BrokerCredential drives, plus the error types
# the refresh and vend paths use to communicate outcomes.
#
# SECURITY: every code path under Broker handles refresh tokens and access tokens
# on the hot path. Logging is restricted to credential ids, OAuth error codes,
# and timestamps -- never the tokens themselves or raw token-endpoint bodies.
module Broker
  class Error < StandardError; end

  # Raised when a credential's input source (client_id/client_secret/header)
  # cannot be resolved inside control -- a misconfiguration, not an IdP failure.
  # The refresh loop treats this as retryable so a transiently-missing env var
  # recovers without marking the credential dead.
  class SourceResolutionError < Error; end

  # Raised by RefreshClient when the token-endpoint round trip fails. `retryable`
  # distinguishes transient failures (network, 5xx, bodyless 4xx, malformed 2xx)
  # from unrecoverable ones (RFC 6749 5.2 error codes), which mark the credential
  # dead until a human re-auths.
  class RefreshError < Error
    STAGES = %w[network http oauth parse].freeze

    attr_reader :stage, :code, :status, :retryable

    def initialize(message, stage:, retryable:, code: nil, status: nil)
      super(message)
      @stage = stage
      @retryable = retryable
      @code = code
      @status = status
    end

    def retryable? = @retryable

    # The label recorded as dead_reason / used for diagnostics: the OAuth error
    # code when present, else the stage.
    def reason = code.presence || stage
  end

  # Vend-path signal: the credential is dead and cannot mint tokens until a human
  # re-auths. Mirrors iron-token-broker's deadError; carries the operator-facing
  # reason for the 422 body.
  class DeadError < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("credential dead: #{reason}")
    end
  end

  # Vend-path signal: AccessToken was called before the credential has ever been
  # refreshed (no blob yet -- the bootstrap window). Mirrors errNotReady; HTTP
  # responds 503 + Retry-After.
  class NotReadyError < Error
    def initialize(message = "credential not ready (bootstrapping)")
      super
    end
  end
end
