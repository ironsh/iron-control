# A managed OAuth credential whose refresh-token lifecycle iron-control owns
# itself: the in-control port of iron-token-broker. control drives a refresh loop
# (Broker::PollRefreshJob -> Broker::RefreshCredentialJob -> #refresh!) that mints
# fresh access tokens before expiry.
#
# The minted access token reaches iron-proxy through the normal /sync path: a
# `token_broker` SecretSource on some grantable secret references this credential
# by `credential_id` (its oid), and SecretSource#to_proxy_source resolves it to
# the current access token, delivered inline like a control_plane value. A
# BrokerCredential is itself NOT synced and NOT grantable.
#
# The OAuth client credentials it refreshes with -- client_id, optional
# client_secret, and any token-endpoint headers -- are fields on the credential,
# resolved by control itself. client_id is not secret; client_secret and the
# header values are encrypted at rest.
class BrokerCredential < ApplicationRecord
  oid_prefix "bcr"

  include ForeignIdCollisionGuard

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  # The access token must keep at least this much life past the scheduled
  # refresh, regardless of slack/fraction. Mirrors the 60s floor in
  # iron-token-broker's nextRefreshAt.
  REFRESH_FLOOR_SECONDS = 60
  # IdPs that omit expires_in get a conservative default so the loop refreshes
  # before the token quietly stops working. Mirrors refreshOnce.
  DEFAULT_EXPIRES_IN_SECONDS = 5 * 60
  # Exponential backoff for retryable failures: base 5s, doubling, capped at 5m.
  BACKOFF_BASE_SECONDS = 5
  BACKOFF_MAX_SECONDS = 5 * 60

  belongs_to :created_by, class_name: "User"

  attr_writer :refresh_client

  serialize :token_endpoint_headers, coder: JSON
  encrypts :access_token
  encrypts :refresh_token
  encrypts :client_secret
  encrypts :token_endpoint_headers

  scope :refreshable, -> {
    where(dead: false).where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
  }

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, uniqueness: { scope: :namespace, allow_nil: true },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }, allow_nil: true
  validates :token_endpoint, presence: true
  validates :client_id, presence: true
  validates :early_refresh_fraction,
            numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :early_refresh_slack_seconds, :max_refresh_interval_seconds, :refresh_timeout_seconds,
            numericality: { only_integer: true, greater_than: 0 }
  validate :labels_is_a_hash
  validate :scopes_is_an_array
  validate :token_endpoint_headers_valid

  # bootstrapping: seeded but never refreshed; dead: needs human re-auth;
  # live: has minted at least one access token.
  def status
    return "dead" if dead?
    return "bootstrapping" if last_refresh.nil?
    "live"
  end

  # --- Refresh state machine (ported from iron-token-broker credential.go) ----

  # The wall-clock time the loop should next refresh. min(early-trigger,
  # max-interval-ceiling) with a 60s floor before expiry. A credential that has
  # never refreshed (no blob) is due immediately.
  def compute_next_attempt_at(now: Time.current)
    return now if expires_at.nil? || last_refresh.nil?

    slack = early_refresh_slack_seconds
    ttl = expires_at - last_refresh
    if early_refresh_fraction.positive? && ttl.positive?
      frac_slack = ttl * early_refresh_fraction
      slack = frac_slack if frac_slack > slack
    end
    slack = REFRESH_FLOOR_SECONDS if slack < REFRESH_FLOOR_SECONDS

    early = expires_at - slack
    ceiling = last_refresh + max_refresh_interval_seconds
    [ early, ceiling ].min
  end

  # Performs one refresh attempt under a row lock (the single-writer guarantee:
  # concurrent refresh attempts serialize on the same row, so the refresh family
  # is never used twice concurrently). Persists the outcome --
  # success advances the blob + schedules the next refresh, a retryable failure
  # schedules a backoff retry, and an unrecoverable failure marks the credential
  # dead. Never raises for an IdP/config failure; the state is in the row.
  def refresh!(now: Time.current)
    with_lock do
      return if dead?
      if refresh_token.blank?
        mark_dead!("blob_not_bootstrapped")
        return
      end

      result = perform_refresh(now: now)
      apply_success!(result, now: now)
    rescue Broker::RefreshError => e
      if e.retryable?
        record_retryable_failure(e.message, now: now)
      else
        mark_dead!(e.reason)
      end
    end
  end

  private

  def refresh_client
    @refresh_client ||= Broker::RefreshClient.new
  end

  def perform_refresh(now:)
    refresh_client.refresh(
      token_endpoint: token_endpoint,
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token,
      scopes: scopes,
      headers: token_endpoint_headers || {},
      timeout: refresh_timeout_seconds
    )
  end

  def apply_success!(result, now:)
    expires_in = result.expires_in&.positive? ? result.expires_in : DEFAULT_EXPIRES_IN_SECONDS
    attrs = {
      access_token: result.access_token,
      expires_at: now + expires_in,
      last_refresh: now,
      failure_count: 0,
      dead: false,
      dead_reason: nil
    }
    # Carry the previous refresh_token forward when the IdP did not rotate.
    attrs[:refresh_token] = result.refresh_token if result.refresh_token.present?
    assign_attributes(attrs)
    self.next_attempt_at = compute_next_attempt_at(now: now)
    save!
    Rails.logger.info { "broker credential #{oid} refreshed; expires_at=#{expires_at.iso8601}" }
  end

  def record_retryable_failure(reason, now:)
    self.failure_count += 1
    self.next_attempt_at = now + backoff_delay(failure_count)
    save!
    Rails.logger.warn { "broker credential #{oid} refresh failed (retryable, attempt #{failure_count}): #{reason}" }
  end

  def mark_dead!(reason)
    update!(dead: true, dead_reason: reason)
    Rails.logger.error { "broker credential #{oid} marked dead; human re-auth required: reason=#{reason}" }
  end

  def backoff_delay(attempt)
    exp = BACKOFF_BASE_SECONDS * (2**[ attempt - 1, 6 ].min)
    [ exp, BACKOFF_MAX_SECONDS ].min
  end

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  def scopes_is_an_array
    return if scopes.is_a?(Array) && scopes.all?(String)
    errors.add(:scopes, "must be an array of strings")
  end

  def token_endpoint_headers_valid
    return if token_endpoint_headers.nil?
    valid = token_endpoint_headers.is_a?(Hash) &&
            token_endpoint_headers.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
    errors.add(:token_endpoint_headers, "must be an object mapping header names to string values") unless valid
  end
end
