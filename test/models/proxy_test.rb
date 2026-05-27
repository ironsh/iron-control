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

  test "requires bearer_token_hash" do
    proxy = Proxy.new(valid_attrs(bearer_token_hash: nil))
    assert_not proxy.valid?
    assert_includes proxy.errors[:bearer_token_hash], "can't be blank"
  end

  test "declares prx as its oid prefix" do
    assert_equal "prx", Proxy.oid_prefix
  end

  test "find_by_oid round-trips" do
    proxy = proxies(:acme_proxy)
    assert_equal proxy, Proxy.find_by_oid(proxy.oid)
  end
end
