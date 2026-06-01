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

  test "requires principal" do
    proxy = Proxy.new(valid_attrs(principal: nil))
    assert_not proxy.valid?
    assert_includes proxy.errors[:principal], "must exist"
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
end
