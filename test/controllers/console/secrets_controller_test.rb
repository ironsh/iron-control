require "test_helper"

module Console
  class SecretsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @operator = users(:acme_admin)
      post login_url, params: { email: @operator.email, password: "password123456" }
    end

    # --- routing / gating -------------------------------------------------

    test "redirects to login when not signed in" do
      delete logout_url
      get new_console_secret_url("static")
      assert_redirected_to login_path
    end

    test "a kind without a form is not found" do
      get new_console_secret_url("hmac")
      assert_response :not_found
    end

    # --- static: new / create --------------------------------------------

    test "GET new renders the static form" do
      get new_console_secret_url("static")
      assert_response :ok
      assert_select "form[action=?]", console_secrets_create_path("static")
    end

    test "POST create builds a static secret with a source and rules" do
      assert_difference -> { StaticSecret.count } => 1,
                        -> { SecretSource.count } => 1,
                        -> { RequestRule.count } => 2 do
        post console_secrets_create_url("static"), params: {
          secret: { namespace: "acme", name: "ui-static", foreign_id: "ui-static" },
          static: { mode: "inject", header: "Authorization", formatter: "Bearer {{ .Value }}" },
          source: { source_type: "env", reference: "UI_TOKEN" },
          rules: {
            "0" => { host: "api.example.com", http_methods: "get, post", paths: "/v1/*" },
            "1" => { host: "api2.example.com", http_methods: "POST", paths: "" }
          },
          labels: { "0" => { key: "team", value: "platform" } }
        }
      end

      secret = StaticSecret.find_by!(namespace: "acme", foreign_id: "ui-static")
      assert_redirected_to console_secret_path("static", secret.oid)
      assert_equal({ "header" => "Authorization", "formatter" => "Bearer {{ .Value }}" }, secret.inject_config)
      assert_equal({ "team" => "platform" }, secret.labels)
      assert_equal "env", secret.source.source_type
      assert_equal({ "var" => "UI_TOKEN" }, secret.source.config)
      assert_equal [ 0, 1 ], secret.rules.order(:position).map(&:position)
      assert_equal %w[GET POST], secret.rules.order(:position).first.http_methods
    end

    test "POST create with no inject or replace re-renders with errors and writes nothing" do
      assert_no_difference [ "StaticSecret.count", "SecretSource.count", "RequestRule.count" ] do
        post console_secrets_create_url("static"), params: {
          secret: { namespace: "acme", name: "broken" },
          static: { mode: "inject" },
          source: { source_type: "env", reference: "X" }
        }
      end
      assert_response :unprocessable_entity
      assert_select "li", /inject_config or replace_config/
    end

    test "POST create surfaces a nested rule error" do
      assert_no_difference [ "StaticSecret.count", "RequestRule.count" ] do
        post console_secrets_create_url("static"), params: {
          secret: { namespace: "acme", name: "bad-rule" },
          static: { mode: "inject", header: "Authorization" },
          rules: { "0" => { host: "h.example.com", cidr: "10.0.0.0/8" } }
        }
      end
      assert_response :unprocessable_entity
      assert_select "li", /Rule 1/
    end

    # --- static: edit / update -------------------------------------------

    test "GET edit renders the form prefilled" do
      secret = static_secrets(:acme_prod_api_key)
      get edit_console_secret_url("static", secret.oid)
      assert_response :ok
      assert_select "input[name=?][value=?]", "secret[foreign_id]", secret.foreign_id
    end

    test "edit renders rule methods as selected chips and paths as tokens" do
      post console_secrets_create_url("static"), params: {
        secret: { namespace: "acme", foreign_id: "chip-render" },
        static: { mode: "inject", header: "Authorization" },
        rules: { "0" => { host: "api.example.com", http_methods: "get, post", paths: "/v1/*" } }
      }
      secret = StaticSecret.find_by!(namespace: "acme", foreign_id: "chip-render")

      get edit_console_secret_url("static", secret.oid)
      assert_response :ok
      assert_select "input[name=?][value=?]", "rules[0][http_methods]", "GET,POST"
      assert_select "button.chip-on[data-method=?]", "GET"
      assert_select "button.chip-on[data-method=?]", "POST"
      assert_select "button[data-method=?]:not(.chip-on)", "DELETE"
      assert_select "span.chip-token[data-value=?]", "/v1/*"
    end

    test "invalid create marks the offending field and renders an inline error" do
      post console_secrets_create_url("static"), params: {
        secret: { namespace: "bad namespace" },
        static: { mode: "inject", header: "Authorization" }
      }
      assert_response :unprocessable_entity
      assert_select "input.form-input-error[name=?]", "secret[namespace]"
      assert_select "p.field-error"
    end

    test "PATCH update changes attributes and replaces rules" do
      secret = static_secrets(:github_token_inject)
      patch console_secret_update_url("static", secret.oid), params: {
        secret: { namespace: secret.namespace, name: "renamed" },
        static: { mode: "inject", header: "X-Token" },
        source: { source_type: "env", reference: "NEW_VAR" },
        rules: { "0" => { host: "only.example.com", http_methods: "GET", paths: "/" } }
      }
      assert_redirected_to console_secret_path("static", secret.oid)
      secret.reload
      assert_equal "renamed", secret.name
      assert_equal({ "header" => "X-Token" }, secret.inject_config)
      assert_equal "NEW_VAR", secret.source.config["var"]
      assert_equal [ "only.example.com" ], secret.rules.map(&:host)
    end

    # --- pg_dsn: create / update -----------------------------------------

    test "GET new renders the pg_dsn form" do
      get new_console_secret_url("pg_dsn")
      assert_response :ok
      assert_select "input[name=?]", "secret[database]"
    end

    test "POST create builds a pg_dsn secret with an inline DSN source" do
      assert_difference -> { PgDsnSecret.count } => 1, -> { SecretSource.count } => 1 do
        post console_secrets_create_url("pg_dsn"), params: {
          secret: { namespace: "acme", foreign_id: "ui-shop", database: "shop", role: "readonly" },
          source: { source_type: "control_plane", secret: "postgres://u:p@db.example:5432/shop" }
        }
      end
      secret = PgDsnSecret.find_by!(namespace: "acme", foreign_id: "ui-shop")
      assert_redirected_to console_secret_path("pg_dsn", secret.oid)
      assert_equal "shop", secret.database
      assert_equal "control_plane", secret.dsn_source.source_type
    end

    test "POST create rejects a database that mismatches the inline DSN" do
      assert_no_difference [ "PgDsnSecret.count", "SecretSource.count" ] do
        post console_secrets_create_url("pg_dsn"), params: {
          secret: { namespace: "acme", foreign_id: "ui-mismatch", database: "wrong" },
          source: { source_type: "control_plane", secret: "postgres://u:p@db.example/shop" }
        }
      end
      assert_response :unprocessable_entity
      assert_select "li", /DSN database/
    end

    test "POST create requires foreign_id and database for pg_dsn" do
      assert_no_difference "PgDsnSecret.count" do
        post console_secrets_create_url("pg_dsn"), params: {
          secret: { namespace: "acme" },
          source: { source_type: "env", reference: "PG_DSN" }
        }
      end
      assert_response :unprocessable_entity
    end

    test "PATCH update changes the pg_dsn database and source" do
      secret = pg_dsn_secrets(:acme_reporting_pg)
      patch console_secret_update_url("pg_dsn", secret.oid), params: {
        secret: { namespace: secret.namespace, foreign_id: secret.foreign_id, database: "reporting", role: "" },
        source: { source_type: "env", reference: "REPORTING_DSN" }
      }
      assert_redirected_to console_secret_path("pg_dsn", secret.oid)
      secret.reload
      assert_nil secret.role.presence
      assert_equal "REPORTING_DSN", secret.dsn_source.config["var"]
    end
  end
end
