require "test_helper"

class ProxyTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    {
      name: "my-proxy",
      principal: principals(:acme_channel),
      bearer_token_hash: Digest::SHA256.hexdigest("token")
    }.merge(overrides)
  end

  test "is valid with name, principal, and bearer_token_hash" do
    proxy = Proxy.new(valid_attrs(principal: principals(:globex_user)))
    assert proxy.valid?
  end

  test "requires name" do
    proxy = Proxy.new(valid_attrs(name: nil))
    assert_not proxy.valid?
    assert_includes proxy.errors[:name], "can't be blank"
  end

  test "is valid without a principal (boots unassigned)" do
    proxy = Proxy.new(valid_attrs(principal: nil))
    assert proxy.valid?
    assert_equal "unassigned", proxy.status
    refute proxy.assigned?
  end

  test "stamps principal_assigned_at when a principal is assigned and clears it on unassign" do
    proxy = Proxy.create!(name: "lifecycle", principal: nil)
    assert_nil proxy.principal_assigned_at

    proxy.update!(principal: principals(:globex_user))
    assert proxy.assigned?
    refute_nil proxy.principal_assigned_at

    proxy.update!(principal: nil)
    assert_nil proxy.principal_assigned_at
    assert_equal "unassigned", proxy.status
  end

  test "an unassigned proxy delivers an empty config" do
    proxy = Proxy.create!(name: "idle", principal: nil)
    assert_empty proxy.sync_secrets
    assert_empty proxy.sync_transforms
    assert_empty proxy.granted_static_secrets
  end

  test "config_hash changes when the principal is swapped" do
    proxy = Proxy.create!(name: "swap", principal: principals(:globex_user))
    before = proxy.config_hash
    proxy.update!(principal: principals(:acme_channel))
    refute_equal before, proxy.config_hash
  end

  test "declares prx as its oid prefix" do
    assert_equal "prx", Proxy.oid_prefix
  end

  test "find_by_oid round-trips" do
    proxy = proxies(:acme_proxy)
    assert_equal proxy, Proxy.find_by_oid(proxy.oid)
  end

  test "issues a plaintext token and matching hash on create" do
    proxy = Proxy.create!(name: "fresh", principal: principals(:globex_user))
    assert proxy.token.start_with?(Proxy::TOKEN_PREFIX)
    assert_match Proxy::TOKEN_FORMAT, proxy.token
    assert_equal Digest::SHA256.hexdigest(proxy.token), proxy.bearer_token_hash
  end

  test "does not overwrite a supplied bearer_token_hash" do
    proxy = Proxy.create!(valid_attrs(principal: principals(:globex_user)))
    assert_nil proxy.token
    assert_equal Digest::SHA256.hexdigest("token"), proxy.bearer_token_hash
  end

  test "find_by_token returns the record for the issued token" do
    proxy = Proxy.create!(name: "lookup", principal: principals(:globex_user))
    assert_equal proxy, Proxy.find_by_token(proxy.token)
  end

  test "find_by_token returns nil for blank or unknown tokens" do
    assert_nil Proxy.find_by_token(nil)
    assert_nil Proxy.find_by_token("")
    assert_nil Proxy.find_by_token("iprx_#{'0' * 64}")
  end

  test "bearer_token_hash is unique" do
    Proxy.create!(name: "first", principal: principals(:globex_user),
                  bearer_token_hash: Digest::SHA256.hexdigest("dup"))
    dup = Proxy.new(name: "second", principal: principals(:globex_user),
                    bearer_token_hash: Digest::SHA256.hexdigest("dup"))
    assert_not dup.valid?
    assert_includes dup.errors[:bearer_token_hash], "has already been taken"
  end

  # --- transform delivery -------------------------------------------------

  def proxy_with_grants(*grantables)
    proxy = Proxy.create!(name: "transform-proxy", principal: principals(:globex_user))
    grantables.each do |g|
      key = Grant::GRANTABLE_ASSOCIATIONS.find { |a| g.is_a?(a.to_s.camelize.constantize) }
      Grant.create!(principal: proxy.principal, key => g, created_by: users(:globex_admin))
    end
    proxy
  end

  test "sync_transforms emits a gcp_auth transform per granted GcpAuthSecret" do
    proxy = proxy_with_grants(gcp_auth_secrets(:acme_bigquery))
    transforms = proxy.sync_transforms
    assert_equal 1, transforms.length
    assert_equal "gcp_auth", transforms.first["name"]
    assert_equal({ "type" => "workload_identity" }, transforms.first.dig("config", "credentials_provider"))
  end

  test "sync_transforms bundles all granted oauth tokens into one transform" do
    proxy = proxy_with_grants(oauth_token_secrets(:acme_gmail_oauth))
    transforms = proxy.sync_transforms
    oauth = transforms.find { |t| t["name"] == "oauth_token" }
    refute_nil oauth
    tokens = oauth.dig("config", "tokens")
    assert_equal 1, tokens.length
    assert_equal "refresh_token", tokens.first["grant"]
  end

  test "sync_transforms is empty without transform grants" do
    proxy = Proxy.create!(name: "bare", principal: principals(:globex_user))
    assert_empty proxy.sync_transforms
  end

  test "config_hash changes when a transform grant is added" do
    proxy = Proxy.create!(name: "hashing", principal: principals(:globex_user))
    before = proxy.config_hash
    Grant.create!(principal: proxy.principal, gcp_auth_secret: gcp_auth_secrets(:acme_bigquery),
                  created_by: users(:globex_admin))
    refute_equal before, proxy.config_hash
  end

  # --- role-based grants --------------------------------------------------

  test "granted_static_secrets includes secrets granted via an assigned role" do
    # acme_channel holds the acme_infra role, which is granted acme_prod_api_key.
    proxy = proxies(:acme_proxy)
    assert_includes proxy.granted_static_secrets, static_secrets(:acme_prod_api_key)
  end

  test "effective grants dedupe a secret reachable both directly and via a role" do
    principal = principals(:acme_channel)
    proxy = proxies(:acme_proxy)
    # acme_prod_api_key already reaches the principal through the acme_infra role;
    # also grant it directly and confirm it still appears exactly once.
    Grant.create!(principal: principal, static_secret: static_secrets(:acme_prod_api_key),
                  created_by: users(:acme_admin))
    ids = proxy.granted_static_secrets.map(&:id)
    assert_equal ids.uniq, ids
    assert_equal 1, ids.count(static_secrets(:acme_prod_api_key).id)
  end

  test "config_hash changes when a role grant becomes reachable" do
    role = Role.create!(namespace: "acme", foreign_id: "extra", created_by: users(:acme_admin))
    proxy = proxies(:acme_proxy)
    before = proxy.config_hash
    Grant.create!(role: role, gcp_auth_secret: gcp_auth_secrets(:acme_bigquery),
                  created_by: users(:acme_admin))
    principals(:acme_channel).principal_roles.create!(role: role)
    refute_equal before, proxy.reload.config_hash
  end
end
