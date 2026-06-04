require "test_helper"

module Api
  module V1
    class BrokerCredentialsControllerTest < ActionDispatch::IntegrationTest
      ACME_TOKEN = "iak_acme-ci-token".freeze

      def auth_headers(token = ACME_TOKEN)
        { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      end

      def json_body = JSON.parse(response.body)

      test "rejects requests without an API key" do
        get api_v1_broker_credentials_url(namespace: "acme")
        assert_response :unauthorized
      end

      test "index lists credentials in a namespace without token material" do
        get api_v1_broker_credentials_url(namespace: "acme"), headers: auth_headers
        assert_response :ok
        row = json_body.fetch("data").first
        assert_equal "bootstrapping", row["status"]
        refute row.key?("access_token")
        refute row.key?("refresh_token")
      end

      test "show returns config and status but never secret material" do
        bc = broker_credentials(:acme_managed_gmail)
        get api_v1_broker_credential_url(id: bc.oid), headers: auth_headers
        assert_response :ok
        data = json_body.fetch("data")
        assert_equal "https://oauth2.googleapis.com/token", data["token_endpoint"]
        assert_equal "gmail-client-id", data["client_id"]
        refute data.key?("client_secret")
        refute data.key?("access_token")
        refute data.key?("refresh_token")
      end

      test "create seeds the refresh_token, schedules it due now, and redacts secrets" do
        body = {
          data: {
            namespace: "acme", foreign_id: "new-managed",
            token_endpoint: "https://idp.example/token",
            scopes: [ "x" ],
            client_id: "the-client-id",
            client_secret: "the-client-secret",
            refresh_token: "super-secret-seed",
            token_endpoint_headers: { "X-Api-Key" => "k" }
          }
        }

        assert_difference -> { BrokerCredential.count } => 1 do
          post api_v1_broker_credentials_url, params: body.to_json, headers: auth_headers
        end
        assert_response :created
        data = json_body.fetch("data")
        assert_equal "the-client-id", data["client_id"]
        refute data.key?("client_secret")
        refute data.key?("refresh_token")
        assert_equal [ "X-Api-Key" ], data["token_endpoint_header_names"]
        assert data["next_attempt_at"].present?, "should be scheduled due"

        created = BrokerCredential.find_by_oid(data["id"])
        assert_equal "super-secret-seed", created.refresh_token # persisted + decryptable
        assert_equal "the-client-secret", created.client_secret
        assert_equal({ "X-Api-Key" => "k" }, created.token_endpoint_headers)
      end

      test "create rejects a missing client_id" do
        body = {
          data: {
            namespace: "acme", foreign_id: "incomplete",
            token_endpoint: "https://idp.example/token",
            client_secret: "sec"
          }
        }
        assert_no_difference -> { BrokerCredential.count } do
          post api_v1_broker_credentials_url, params: body.to_json, headers: auth_headers
        end
        assert_response :unprocessable_entity
      end

      test "re-auth via PUT clears dead state and reschedules" do
        bc = broker_credentials(:acme_managed_gmail)
        bc.update!(dead: true, dead_reason: "invalid_grant", failure_count: 3)

        body = { data: { refresh_token: "fresh-seed" } }
        put api_v1_broker_credential_url(id: bc.oid), params: body.to_json, headers: auth_headers
        assert_response :ok

        bc.reload
        refute bc.dead?
        assert_nil bc.dead_reason
        assert_equal 0, bc.failure_count
        assert_equal "fresh-seed", bc.refresh_token
      end

      test "destroy removes the credential" do
        bc = broker_credentials(:globex_managed_api)
        assert_difference -> { BrokerCredential.count } => -1 do
          delete api_v1_broker_credential_url(id: bc.oid), headers: auth_headers(token = "iak_globex-ci-token")
        end
        assert_response :no_content
      end
    end
  end
end
