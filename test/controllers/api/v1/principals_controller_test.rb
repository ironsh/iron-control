require "test_helper"

module Api
  module V1
    class PrincipalsControllerTest < ActionDispatch::IntegrationTest
      ACME_TOKEN = "iak_acme-ci-token".freeze

      def auth_headers(token = ACME_TOKEN)
        { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      end

      def json_body
        JSON.parse(response.body)
      end

      test "rejects requests without an Authorization header" do
        get api_v1_principal_url(id: "prn_unknown")
        assert_response :unauthorized
        assert_equal "invalid or missing API key", json_body.dig("error", "message")
      end

      test "rejects requests with an unknown bearer token" do
        get api_v1_principal_url(id: "prn_unknown"),
            headers: auth_headers("iak_not-a-real-token")
        assert_response :unauthorized
      end

      test "rejects requests with a malformed Authorization scheme" do
        get api_v1_principal_url(id: "prn_unknown"),
            headers: { "Authorization" => "Token #{ACME_TOKEN}" }
        assert_response :unauthorized
      end

      test "GET returns a Principal with its labels" do
        principal = principals(:acme_channel)

        get api_v1_principal_url(id: principal.oid), headers: auth_headers
        assert_response :ok

        data = json_body.fetch("data")
        assert_equal principal.oid, data["id"]
        assert_equal "acme", data["namespace"]
        assert_equal "C0123456789", data["foreign_id"]
        assert_equal({ "kind" => "slack_channel", "team" => "platform" }, data["labels"])
      end

      test "GET returns 404 for an unknown oid" do
        get api_v1_principal_url(id: "prn_nope"), headers: auth_headers
        assert_response :not_found
      end

      test "POST creates a Principal" do
        body = {
          data: {
            namespace: "acme",
            foreign_id: "U-new-id",
            labels: { "kind" => "user", "team" => "platform" }
          }
        }

        assert_difference -> { Principal.count } => 1 do
          post api_v1_principals_url, params: body.to_json, headers: auth_headers
        end
        assert_response :created

        data = json_body.fetch("data")
        assert_match(/\Aprn_/, data["id"])
        assert_equal "acme", data["namespace"]
        assert_equal "U-new-id", data["foreign_id"]
        assert_equal({ "kind" => "user", "team" => "platform" }, data["labels"])
      end

      test "POST returns 422 when namespace is missing" do
        body = { data: { foreign_id: "U-no-namespace" } }

        assert_no_difference -> { Principal.count } do
          post api_v1_principals_url, params: body.to_json, headers: auth_headers
        end
        assert_response :unprocessable_content
        assert_equal "validation failed", json_body.dig("error", "message")
      end

      test "POST returns 422 when (namespace, foreign_id) already exists" do
        existing = principals(:acme_channel)
        body = {
          data: { namespace: existing.namespace, foreign_id: existing.foreign_id }
        }

        assert_no_difference -> { Principal.count } do
          post api_v1_principals_url, params: body.to_json, headers: auth_headers
        end
        assert_response :unprocessable_content
      end

      test "POST returns 400 when the data key is missing" do
        post api_v1_principals_url, params: { namespace: "acme" }.to_json, headers: auth_headers
        assert_response :bad_request
      end

      test "PUT updates labels" do
        principal = principals(:acme_channel)
        body = {
          data: { labels: { "kind" => "slack_channel", "team" => "ops" } }
        }

        put api_v1_principal_url(id: principal.oid), params: body.to_json, headers: auth_headers
        assert_response :ok

        principal.reload
        assert_equal({ "kind" => "slack_channel", "team" => "ops" }, principal.labels)
      end

      test "PUT ignores attempts to change immutable namespace and foreign_id" do
        principal = principals(:acme_channel)
        original_namespace = principal.namespace
        original_foreign_id = principal.foreign_id

        body = {
          data: {
            namespace: "different-namespace",
            foreign_id: "different-foreign-id",
            labels: { "kind" => "slack_channel" }
          }
        }

        put api_v1_principal_url(id: principal.oid), params: body.to_json, headers: auth_headers
        assert_response :ok

        principal.reload
        assert_equal original_namespace, principal.namespace
        assert_equal original_foreign_id, principal.foreign_id
      end

      test "PUT returns 404 for an unknown oid" do
        put api_v1_principal_url(id: "prn_nope"),
            params: { data: { labels: {} } }.to_json,
            headers: auth_headers
        assert_response :not_found
      end
    end
  end
end
