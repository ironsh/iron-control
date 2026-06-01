require "test_helper"

class ProxiesControllerTest < ActionDispatch::IntegrationTest
  ACME_TOKEN = "iak_acme-ci-token".freeze

  def auth_headers(token = ACME_TOKEN)
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  end

  def json_body
    JSON.parse(response.body)
  end

  test "rejects requests without an Authorization header" do
    get api_v1_proxies_url
    assert_response :unauthorized
  end

  test "GET index lists proxies" do
    get api_v1_proxies_url, headers: auth_headers
    assert_response :ok
    ids = json_body.fetch("data").map { |d| d["id"] }
    assert_includes ids, proxies(:acme_proxy).oid
    assert_includes ids, proxies(:globex_proxy).oid
  end

  test "GET index filters by principal_id" do
    get api_v1_proxies_url, params: { principal_id: principals(:acme_channel).oid }, headers: auth_headers
    assert_response :ok
    ids = json_body.fetch("data").map { |d| d["id"] }
    assert_includes ids, proxies(:acme_proxy).oid
    refute_includes ids, proxies(:globex_proxy).oid
  end

  test "GET show returns a proxy" do
    proxy = proxies(:acme_proxy)
    get api_v1_proxy_url(id: proxy.oid), headers: auth_headers
    assert_response :ok
    data = json_body.fetch("data")
    assert_equal proxy.oid, data["id"]
    assert_equal proxy.principal.oid, data["principal_id"]
    refute data.key?("token")
  end

  test "POST creates a proxy and returns the plaintext token once" do
    body = { data: { name: "edge-proxy", principal_id: principals(:acme_channel).oid } }
    assert_difference -> { Proxy.count }, 1 do
      post api_v1_proxies_url, params: body.to_json, headers: auth_headers
    end
    assert_response :created

    data = json_body.fetch("data")
    token = data.fetch("token")
    assert_match Proxy::TOKEN_FORMAT, token
    assert_equal Proxy.find_by_token(token).oid, data["id"]
  end

  test "POST with a missing name returns a validation error" do
    body = { data: { principal_id: principals(:acme_channel).oid } }
    post api_v1_proxies_url, params: body.to_json, headers: auth_headers
    assert_response :unprocessable_entity
    assert_equal "validation failed", json_body.dig("error", "message")
  end

  test "POST with an unknown principal returns not found" do
    body = { data: { name: "x", principal_id: "prn_doesnotexist" } }
    post api_v1_proxies_url, params: body.to_json, headers: auth_headers
    assert_response :not_found
  end

  test "DELETE removes a proxy" do
    proxy = proxies(:globex_proxy)
    assert_difference -> { Proxy.count }, -1 do
      delete api_v1_proxy_url(id: proxy.oid), headers: auth_headers
    end
    assert_response :no_content
  end
end
