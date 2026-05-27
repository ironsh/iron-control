require "test_helper"

class GrantTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    {
      principal: principals(:acme_channel),
      static_secret_ref: static_secret_refs(:github_token_inject),
      created_by: api_keys(:acme_ci_key)
    }.merge(overrides)
  end

  test "is valid with principal and static_secret_ref" do
    grant = Grant.new(valid_attrs(principal: principals(:globex_user)))
    assert grant.valid?
  end

  test "requires principal" do
    grant = Grant.new(valid_attrs(principal: nil))
    assert_not grant.valid?
    assert_includes grant.errors[:principal], "must exist"
  end

  test "requires static_secret_ref" do
    grant = Grant.new(valid_attrs(static_secret_ref: nil))
    assert_not grant.valid?
    assert_includes grant.errors[:static_secret_ref], "must exist"
  end

  test "principal is immutable after creation" do
    grant = grants(:acme_channel_github_token)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      grant.update!(principal: principals(:globex_user))
    end
  end

  test "static_secret_ref is immutable after creation" do
    grant = grants(:acme_channel_github_token)
    other = static_secret_refs(:db_password_replace)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      grant.update!(static_secret_ref: other)
    end
  end

  test "destroyed when principal is destroyed" do
    principal = principals(:acme_channel)
    grant_ids = principal.grants.pluck(:id)
    assert_not_empty grant_ids
    principal.destroy!
    assert_equal 0, Grant.where(id: grant_ids).count
  end

  test "destroyed when static_secret_ref is destroyed" do
    ref = static_secret_refs(:github_token_inject)
    grant_ids = ref.grants.pluck(:id)
    assert_not_empty grant_ids
    ref.destroy!
    assert_equal 0, Grant.where(id: grant_ids).count
  end

  test "declares grant as its oid prefix" do
    assert_equal "grant", Grant.oid_prefix
  end

  test "find_by_oid round-trips" do
    grant = grants(:acme_channel_github_token)
    assert_equal grant, Grant.find_by_oid(grant.oid)
  end
end
