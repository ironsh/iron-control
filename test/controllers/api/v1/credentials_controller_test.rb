require "test_helper"

module Api
  module V1
    class CredentialsControllerTest < ActionDispatch::IntegrationTest
      PROXY_TOKEN = "iprx_#{'a' * 64}".freeze # acme_proxy fixture

      def auth_headers(token = PROXY_TOKEN)
        { "Authorization" => "Bearer #{token}" }
      end

      def json_body = JSON.parse(response.body)

      # A persisted credential with a control_plane client_id source. The blob is
      # set per-test via the model so encryption applies.
      def make_credential
        bc = BrokerCredential.new(namespace: "default", foreign_id: "vend-#{SecureRandom.hex(4)}",
                                  token_endpoint: "https://idp.example/token",
                                  created_by: users(:acme_admin), refresh_token: "seed")
        bc.sources.build(source_type: "control_plane", secret: "cid", role: "client_id", role_kind: "credential_field")
        bc.save!
        bc
      end

      test "rejects requests without a proxy token" do
        bc = make_credential
        get "/api/v1/credentials/#{bc.oid}/access_token"
        assert_response :unauthorized
      end

      test "rejects an ApiKey token (proxy auth only)" do
        bc = make_credential
        get "/api/v1/credentials/#{bc.oid}/access_token", headers: auth_headers("iak_acme-ci-token")
        assert_response :unauthorized
      end

      test "vends a cached access token in the raw broker body shape" do
        bc = make_credential
        bc.update!(access_token: "AT-cached", expires_at: 1.hour.from_now, last_refresh: Time.current)

        get "/api/v1/credentials/#{bc.oid}/access_token", headers: auth_headers
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        # Raw body, NOT wrapped in {data:...}.
        assert_equal "AT-cached", json_body["access_token"]
        assert json_body["expires_at"].present?
        refute json_body.key?("data")
        refute json_body.key?("refresh_token")
      end

      test "returns 422 for a dead credential" do
        bc = make_credential
        bc.update!(dead: true, dead_reason: "invalid_grant")
        get "/api/v1/credentials/#{bc.oid}/access_token", headers: auth_headers
        assert_response :unprocessable_entity
        assert_equal "invalid_grant", json_body["reason"]
      end

      test "returns 503 with Retry-After while bootstrapping" do
        bc = make_credential # never refreshed, no blob
        get "/api/v1/credentials/#{bc.oid}/access_token", headers: auth_headers
        assert_response :service_unavailable
        assert_equal "5", response.headers["Retry-After"]
      end

      test "returns 404 for an unknown credential" do
        get "/api/v1/credentials/bcr_unknown/access_token", headers: auth_headers
        assert_response :not_found
      end
    end
  end
end
