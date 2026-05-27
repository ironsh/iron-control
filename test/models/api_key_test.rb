require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { user: users(:acme_admin), name: "deploy" }.merge(overrides)
  end

  test "is valid with user and name" do
    assert ApiKey.new(valid_attrs(user: users(:globex_admin))).valid?
  end

  test "requires user" do
    key = ApiKey.new(valid_attrs(user: nil))
    assert_not key.valid?
    assert_includes key.errors[:user], "must exist"
  end

  test "requires name" do
    key = ApiKey.new(valid_attrs(name: nil))
    assert_not key.valid?
    assert_includes key.errors[:name], "can't be blank"
  end

  test "generates plaintext token and matching hash on create" do
    key = ApiKey.create!(valid_attrs(user: users(:globex_admin)))
    assert key.token.start_with?("iak_")
    assert_equal Digest::SHA256.hexdigest(key.token), key.token_hash
  end

  test "find_by_token returns the record" do
    key = ApiKey.create!(valid_attrs(user: users(:globex_admin)))
    assert_equal key, ApiKey.find_by_token(key.token)
  end

  test "find_by_token returns nil for unknown tokens" do
    assert_nil ApiKey.find_by_token("iak_nope")
    assert_nil ApiKey.find_by_token(nil)
    assert_nil ApiKey.find_by_token("")
  end

  test "user_id is read-only after creation" do
    key = api_keys(:acme_ci_key)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      key.update!(user: users(:globex_admin))
    end
  end

  test "token_hash is read-only after creation" do
    key = api_keys(:acme_ci_key)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      key.update!(token_hash: Digest::SHA256.hexdigest("other"))
    end
  end

  test "declares ak as its oid prefix" do
    assert_equal "ak", ApiKey.oid_prefix
  end

  test "find_by_oid round-trips" do
    key = api_keys(:acme_ci_key)
    assert_equal key, ApiKey.find_by_oid(key.oid)
  end
end
