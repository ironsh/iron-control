require "test_helper"

module Broker
  class JobsTest < ActiveJob::TestCase
    # client_id resolves from an unset env var, so #refresh! fails fast with a
    # SourceResolutionError (retryable) -- no network, and a visible DB effect
    # (failure_count) proving the job drove the refresh.
    def make_credential(**overrides)
      bc = BrokerCredential.new({
        namespace: "default", foreign_id: "job-#{SecureRandom.hex(4)}",
        token_endpoint: "https://idp.example/token",
        created_by: users(:acme_admin), refresh_token: "seed"
      }.merge(overrides))
      bc.sources.build(source_type: "env", config: { "var" => "UNSET_#{SecureRandom.hex(4)}" },
                       role: "client_id", role_kind: "credential_field")
      bc.save!
      bc
    end

    test "PollRefreshJob enqueues a refresh only for due credentials" do
      due = make_credential
      due.update_columns(next_attempt_at: 1.minute.ago)
      future = make_credential
      future.update_columns(next_attempt_at: 1.hour.from_now)

      Broker::PollRefreshJob.perform_now

      enqueued_ids = enqueued_jobs
        .select { |j| j[:job] == Broker::RefreshCredentialJob }
        .map { |j| j[:args].first }
      assert_includes enqueued_ids, due.id
      refute_includes enqueued_ids, future.id
    end

    test "RefreshCredentialJob drives the credential refresh" do
      bc = make_credential
      assert_equal 0, bc.failure_count
      Broker::RefreshCredentialJob.perform_now(bc.id)
      bc.reload
      # The refresh ran (and failed retryably on the unresolvable source).
      assert_equal 1, bc.failure_count
      refute bc.dead?
    end

    test "RefreshCredentialJob is a no-op for a missing credential" do
      assert_nothing_raised { Broker::RefreshCredentialJob.perform_now(-1) }
    end
  end
end
