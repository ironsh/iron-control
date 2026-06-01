require "test_helper"

class ProxySyncControllerTest < ActionDispatch::IntegrationTest
  ACME_TOKEN = "iprx_#{'a' * 64}".freeze

  def auth_headers(token = ACME_TOKEN)
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  def json_body
    JSON.parse(response.body)
  end

  setup do
    @proxy = proxies(:acme_proxy)

    # acme_channel (the proxy's principal) is granted github_token_inject and
    # db_password_replace. Give them sources so they materialize into the sync
    # payload: an env source and an inline control_plane source.
    @inject = static_secrets(:github_token_inject)
    @replace = static_secrets(:db_password_replace)

    SecretSource.create!(source_type: "env", config: { "var" => "GITHUB_TOKEN" }, static_secret: @inject)
    SecretSource.create!(source_type: "control_plane", secret: "s3cr3t-db-pass", static_secret: @replace)

    RequestRule.create!(host: "api.example.com", http_methods: [ "POST" ], paths: [ "/v1/*" ],
                        position: 0, static_secret: @inject)
  end

  test "rejects requests without an Authorization header" do
    post api_v1_proxy_sync_url, params: {}.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "rejects an unknown token" do
    post api_v1_proxy_sync_url, params: {}.to_json, headers: auth_headers("iprx_#{'9' * 64}")
    assert_response :unauthorized
  end

  test "returns config_hash and secrets when no hash is supplied" do
    post api_v1_proxy_sync_url, params: {}.to_json, headers: auth_headers
    assert_response :ok

    body = json_body
    assert_match(/\Asha256:[0-9a-f]{64}\z/, body.fetch("config_hash"))
    secrets = body.fetch("secrets")
    assert_equal 2, secrets.length

    # Omitted top-level fields stay absent so the proxy no-ops on them.
    refute body.key?("rules")
    refute body.key?("mcp")
    refute body.key?("ingest_token")
  end

  test "env source maps inject_config and rules (http_methods -> methods)" do
    post api_v1_proxy_sync_url, params: {}.to_json, headers: auth_headers
    assert_response :ok

    entry = json_body.fetch("secrets").find { |s| s.dig("source", "type") == "env" }
    refute_nil entry
    assert_equal "GITHUB_TOKEN", entry.dig("source", "var")
    assert_equal({ "header" => "Authorization", "formatter" => "Bearer {{ .Value }}" }, entry["inject"])
    assert_nil entry["replace"]

    rule = entry.fetch("rules").first
    assert_equal "api.example.com", rule["host"]
    assert_equal [ "POST" ], rule["methods"]
    assert_equal [ "/v1/*" ], rule["paths"]
    refute rule.key?("http_methods")
  end

  test "control_plane source delivers the decrypted value inline" do
    post api_v1_proxy_sync_url, params: {}.to_json, headers: auth_headers
    assert_response :ok

    entry = json_body.fetch("secrets").find { |s| s.dig("source", "type") == "control_plane" }
    refute_nil entry
    assert_equal "s3cr3t-db-pass", entry.dig("source", "value")
    assert_equal "__DB_PASSWORD__", entry.dig("replace", "proxy_value")
    assert_nil entry["inject"]
  end

  test "matching config_hash returns only the hash, no secrets" do
    current = @proxy.config_hash

    post api_v1_proxy_sync_url, params: { config_hash: current }.to_json, headers: auth_headers
    assert_response :ok

    body = json_body
    assert_equal current, body.fetch("config_hash")
    refute body.key?("secrets")
  end

  test "stale config_hash returns the full payload" do
    post api_v1_proxy_sync_url, params: { config_hash: "sha256:#{'0' * 64}" }.to_json, headers: auth_headers
    assert_response :ok
    assert_equal 2, json_body.fetch("secrets").length
  end

  test "secrets without a source are skipped" do
    # Grant a sourceless static secret to the same principal.
    sourceless = StaticSecret.create!(
      namespace: "acme", name: "no-source",
      inject_config: { "header" => "X-Token" }, created_by: users(:acme_admin)
    )
    Grant.create!(principal: @proxy.principal, static_secret: sourceless, created_by: users(:acme_admin))

    post api_v1_proxy_sync_url, params: {}.to_json, headers: auth_headers
    assert_response :ok
    # Still only the two sourced secrets.
    assert_equal 2, json_body.fetch("secrets").length
  end

  test "config_hash is stable across identical requests" do
    first = @proxy.config_hash
    second = Proxy.find(@proxy.id).config_hash
    assert_equal first, second
  end
end
