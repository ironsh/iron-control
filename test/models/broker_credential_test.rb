require "test_helper"

class BrokerCredentialTest < ActiveSupport::TestCase
  # A stub refresh client returning a fixed Result or raising a fixed error.
  class StubClient
    def initialize(&block) = (@block = block)
    def refresh(**kw) = @block.call(**kw)
  end

  def result(access_token: "AT", refresh_token: "RT", expires_in: 3600)
    Broker::RefreshClient::Result.new(access_token: access_token, refresh_token: refresh_token, expires_in: expires_in)
  end

  def build_credential(refresh_token: "seed-rt", **overrides)
    bc = BrokerCredential.new({
      namespace: "default", foreign_id: "cred-#{SecureRandom.hex(4)}",
      token_endpoint: "https://idp.example/token", scopes: %w[a b],
      created_by: users(:acme_admin), refresh_token: refresh_token
    }.merge(overrides))
    bc.sources.build(source_type: "control_plane", secret: "cid", role: "client_id", role_kind: "credential_field")
    bc.sources.build(source_type: "control_plane", secret: "sec", role: "client_secret", role_kind: "credential_field")
    bc
  end

  def create_credential(**kw)
    bc = build_credential(**kw)
    bc.save!
    bc
  end

  # --- validations ----------------------------------------------------------

  test "valid with a client_id source" do
    assert build_credential.valid?
  end

  test "invalid without a client_id source" do
    bc = BrokerCredential.new(namespace: "default", token_endpoint: "https://idp.example/token", created_by: users(:acme_admin))
    refute bc.valid?
    assert(bc.errors[:sources].any? { |m| m.include?("client_id") })
  end

  test "invalid with a non-control-resolvable source" do
    bc = build_credential
    bc.sources.first.source_type = "aws_sm"
    bc.sources.first.config = { "secret_id" => "x" }
    bc.sources.first.secret = nil
    refute bc.valid?
    assert(bc.errors[:sources].any? { |m| m.include?("not resolvable inside control") })
  end

  test "early_refresh_fraction must be in [0,1)" do
    refute build_credential(early_refresh_fraction: 1.0).valid?
    refute build_credential(early_refresh_fraction: -0.1).valid?
    assert build_credential(early_refresh_fraction: 0.5).valid?
  end

  # --- compute_next_attempt_at ----------------------------------------------

  test "next attempt is now when never refreshed" do
    now = Time.current
    bc = build_credential
    assert_in_delta now.to_f, bc.compute_next_attempt_at(now: now).to_f, 1
  end

  test "next attempt uses the larger of slack and fraction, with a 60s floor" do
    now = Time.current
    # ttl 3600, fraction 0.2 => 720s slack beats the 300s default slack.
    bc = build_credential(early_refresh_slack_seconds: 300, early_refresh_fraction: 0.2)
    bc.last_refresh = now
    bc.expires_at = now + 3600
    assert_in_delta (now + 3600 - 720).to_f, bc.compute_next_attempt_at(now: now).to_f, 1
  end

  test "next attempt is capped by the max refresh interval ceiling" do
    now = Time.current
    bc = build_credential(early_refresh_slack_seconds: 10, early_refresh_fraction: 0.0, max_refresh_interval_seconds: 100)
    bc.last_refresh = now
    bc.expires_at = now + 100_000 # early trigger far in the future
    assert_in_delta (now + 100).to_f, bc.compute_next_attempt_at(now: now).to_f, 1
  end

  # --- refresh! state machine -----------------------------------------------

  test "successful refresh advances the blob and schedules the next attempt" do
    now = Time.current
    bc = create_credential
    bc.refresh_client = StubClient.new { result(access_token: "AT-1", refresh_token: "RT-2", expires_in: 3600) }
    bc.refresh!(now: now)
    bc.reload
    assert_equal "live", bc.status
    assert_equal "AT-1", bc.access_token
    assert_equal "RT-2", bc.refresh_token
    assert_equal 0, bc.failure_count
    assert_in_delta (now + 3600).to_f, bc.expires_at.to_f, 1
    assert bc.next_attempt_at > now
  end

  test "refresh carries the previous refresh_token forward when the IdP omits it" do
    bc = create_credential(refresh_token: "RT-keep")
    bc.refresh_client = StubClient.new { result(refresh_token: nil, expires_in: nil) }
    bc.refresh!
    bc.reload
    assert_equal "RT-keep", bc.refresh_token
  end

  test "refresh defaults expiry when the IdP omits expires_in" do
    now = Time.current
    bc = create_credential
    bc.refresh_client = StubClient.new { result(expires_in: nil) }
    bc.refresh!(now: now)
    bc.reload
    assert_in_delta (now + BrokerCredential::DEFAULT_EXPIRES_IN_SECONDS).to_f, bc.expires_at.to_f, 1
  end

  test "retryable failure schedules a backoff and does not mark dead" do
    now = Time.current
    bc = create_credential
    bc.refresh_client = StubClient.new { raise Broker::RefreshError.new("net", stage: "network", retryable: true) }
    bc.refresh!(now: now)
    bc.reload
    refute bc.dead?
    assert_equal 1, bc.failure_count
    assert_in_delta (now + BrokerCredential::BACKOFF_BASE_SECONDS).to_f, bc.next_attempt_at.to_f, 1
  end

  test "unrecoverable failure marks the credential dead" do
    bc = create_credential
    bc.refresh_client = StubClient.new { raise Broker::RefreshError.new("bad", stage: "oauth", code: "invalid_grant", retryable: false) }
    bc.refresh!
    bc.reload
    assert bc.dead?
    assert_equal "invalid_grant", bc.dead_reason
  end

  test "source resolution failure is retryable" do
    # An env client_id source pointing at an unset var can't be resolved inside
    # control -> SourceResolutionError, classified retryable (not dead).
    bc = BrokerCredential.new(namespace: "default", foreign_id: "res-#{SecureRandom.hex(4)}",
                              token_endpoint: "https://idp.example/token",
                              created_by: users(:acme_admin), refresh_token: "seed")
    bc.sources.build(source_type: "env", config: { "var" => "DEFINITELY_UNSET_#{SecureRandom.hex(4)}" },
                     role: "client_id", role_kind: "credential_field")
    bc.save!
    bc.refresh!
    bc.reload
    refute bc.dead?
    assert_equal 1, bc.failure_count
  end

  test "refresh with no seed marks dead as not bootstrapped" do
    bc = create_credential(refresh_token: "seed")
    bc.update_columns(refresh_token: nil)
    bc.reload
    bc.refresh!
    bc.reload
    assert bc.dead?
    assert_equal "blob_not_bootstrapped", bc.dead_reason
  end

  # --- access_token! (vend path) --------------------------------------------

  test "access_token returns the cached token without refreshing" do
    now = Time.current
    bc = create_credential
    bc.update!(access_token: "cached", expires_at: now + 1.hour, last_refresh: now)
    bc.refresh_client = StubClient.new { flunk "should not refresh a fresh token" }
    token, expires_at = bc.access_token!(now: now)
    assert_equal "cached", token
    assert_in_delta (now + 1.hour).to_f, expires_at.to_f, 1
  end

  test "access_token refreshes a stale token in-band" do
    now = Time.current
    bc = create_credential
    bc.update!(access_token: "stale", expires_at: now - 1.minute, last_refresh: now - 1.hour)
    bc.refresh_client = StubClient.new { result(access_token: "fresh", expires_in: 3600) }
    token, = bc.access_token!(now: now)
    assert_equal "fresh", token
  end

  test "access_token raises NotReady before any refresh" do
    bc = create_credential
    assert_raises(Broker::NotReadyError) { bc.access_token! }
  end

  test "access_token raises Dead when dead" do
    bc = create_credential
    bc.update!(dead: true, dead_reason: "invalid_grant")
    err = assert_raises(Broker::DeadError) { bc.access_token! }
    assert_equal "invalid_grant", err.reason
  end

  # --- scope ----------------------------------------------------------------

  test "refreshable includes never-attempted and due, excludes dead and future" do
    due = create_credential
    due.update_columns(next_attempt_at: 1.minute.ago)
    future = create_credential
    future.update_columns(next_attempt_at: 1.hour.from_now)
    dead = create_credential
    dead.update_columns(dead: true, next_attempt_at: 1.minute.ago)
    never = create_credential # next_attempt_at nil

    ids = BrokerCredential.refreshable.pluck(:id)
    assert_includes ids, due.id
    assert_includes ids, never.id
    refute_includes ids, future.id
    refute_includes ids, dead.id
  end
end
