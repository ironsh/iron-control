require "test_helper"

module Api
  module V1
    class PgDsnSecretsControllerTest < ActionDispatch::IntegrationTest
      ACME_TOKEN = "iak_acme-ci-token".freeze

      def auth_headers(token = ACME_TOKEN)
        { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      end

      def json_body
        JSON.parse(response.body)
      end

      test "rejects requests without an Authorization header" do
        get api_v1_pg_dsn_secret_url(id: "pgs_unknown")
        assert_response :unauthorized
      end

      test "GET returns a pg_dsn secret with its dsn source" do
        secret = pg_dsn_secrets(:acme_analytics_pg)
        get api_v1_pg_dsn_secret_url(id: secret.oid), headers: auth_headers
        assert_response :ok

        data = json_body.fetch("data")
        assert_equal secret.oid, data["id"]
        assert_equal "readonly", data["role"]
        assert_equal({ "source_type" => "env", "config" => { "var" => "PG_ANALYTICS_DSN" } }, data["dsn"])
        # Listener/client config is a proxy-host concern and is not modeled here.
        refute data.key?("listen")
        refute data.key?("client_user")
      end

      test "GET lookup finds a pg_dsn secret by namespace and foreign_id" do
        secret = pg_dsn_secrets(:acme_analytics_pg)
        get lookup_api_v1_pg_dsn_secrets_url(namespace: secret.namespace, foreign_id: secret.foreign_id),
            headers: auth_headers
        assert_response :ok
        assert_equal secret.oid, json_body.dig("data", "id")
      end

      test "GET lookup scopes a pg_dsn secret by namespace" do
        secret = pg_dsn_secrets(:acme_analytics_pg)
        get lookup_api_v1_pg_dsn_secrets_url(namespace: "globex", foreign_id: secret.foreign_id),
            headers: auth_headers
        assert_response :not_found
      end

      test "GET lookup returns 404 when no pg_dsn secret matches" do
        get lookup_api_v1_pg_dsn_secrets_url(namespace: "acme", foreign_id: "does-not-exist"),
            headers: auth_headers
        assert_response :not_found
      end

      test "POST creates a pg_dsn secret with a nested dsn source" do
        body = {
          data: {
            namespace: "acme",
            foreign_id: "new-pg",
            name: "orders",
            role: "app",
            dsn: { source_type: "aws_sm", config: { secret_id: "arn:db-dsn" } }
          }
        }

        assert_difference -> { PgDsnSecret.count } => 1 do
          post api_v1_pg_dsn_secrets_url, params: body.to_json, headers: auth_headers
        end
        assert_response :created

        secret = PgDsnSecret.find_by_oid(json_body.dig("data", "id"))
        assert_equal "aws_sm", secret.dsn_source.source_type
        assert_equal "app", secret.role
      end

      test "POST never echoes a control_plane dsn secret back" do
        body = {
          data: {
            namespace: "acme",
            foreign_id: "inline-pg",
            dsn: { source_type: "control_plane", secret: "postgres://u:sup3rsecret@db/app" }
          }
        }

        post api_v1_pg_dsn_secrets_url, params: body.to_json, headers: auth_headers
        assert_response :created
        refute_includes response.body, "sup3rsecret"
      end

      test "POST without a dsn source is rejected" do
        body = {
          data: {
            namespace: "acme",
            foreign_id: "no-dsn"
          }
        }

        assert_no_difference -> { PgDsnSecret.count } do
          post api_v1_pg_dsn_secrets_url, params: body.to_json, headers: auth_headers
        end
        assert_response :unprocessable_entity
      end

      test "PUT replaces the dsn source and role" do
        secret = pg_dsn_secrets(:acme_analytics_pg)
        body = {
          data: {
            role: "writer",
            dsn: { source_type: "env", config: { var: "ROTATED_DSN" } }
          }
        }

        put api_v1_pg_dsn_secret_url(id: secret.oid), params: body.to_json, headers: auth_headers
        assert_response :ok

        secret.reload
        assert_equal "ROTATED_DSN", secret.dsn_source.config["var"]
        assert_equal "writer", secret.role
      end

      test "PUT upserts a new pg_dsn secret by foreign_id" do
        body = {
          data: {
            namespace: "acme",
            dsn: { source_type: "env", config: { var: "UPSERT_DSN" } }
          }
        }

        assert_difference -> { PgDsnSecret.count } => 1 do
          put api_v1_pg_dsn_secret_url(id: "pg-upsert"), params: body.to_json, headers: auth_headers
        end
        assert_response :created
        assert_equal "pg-upsert", json_body.dig("data", "foreign_id")
      end

      test "GET index is scoped by namespace" do
        get api_v1_pg_dsn_secrets_url, params: { namespace: "acme" }, headers: auth_headers
        assert_response :ok
        ids = json_body.fetch("data").map { |r| r["id"] }
        assert_includes ids, pg_dsn_secrets(:acme_analytics_pg).oid
      end
    end
  end
end
