require "test_helper"

class UserTest < ActiveSupport::TestCase
  def valid_attrs(overrides = {})
    { email: "new-user@example.com", password: "password123456" }.merge(overrides)
  end

  test "is valid with email and password" do
    assert User.new(valid_attrs).valid?
  end

  test "requires email" do
    user = User.new(valid_attrs(email: nil))
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "rejects malformed email" do
    user = User.new(valid_attrs(email: "not-an-email"))
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "email is unique" do
    existing = users(:acme_admin)
    dup = User.new(valid_attrs(email: existing.email))
    assert_not dup.valid?
    assert_includes dup.errors[:email], "has already been taken"
  end

  test "email is normalized to lowercase and stripped" do
    user = User.create!(valid_attrs(email: "  Mixed@Case.EXAMPLE  "))
    assert_equal "mixed@case.example", user.email
  end

  test "email uniqueness is case-insensitive via normalization" do
    existing = users(:acme_admin)
    dup = User.new(valid_attrs(email: existing.email.upcase))
    assert_not dup.valid?
    assert_includes dup.errors[:email], "has already been taken"
  end

  test "is valid without a password (SSO-only user)" do
    user = User.new(valid_attrs.except(:password))
    assert user.valid?
  end

  test "rejects short passwords" do
    user = User.new(valid_attrs(password: "short"))
    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 12 characters)"
  end

  test "authenticate returns user with correct password" do
    user = User.create!(valid_attrs)
    assert_equal user, user.authenticate("password123456")
  end

  test "authenticate returns false with wrong password" do
    user = User.create!(valid_attrs)
    assert_equal false, user.authenticate("wrong-password!!")
  end

  test "declares usr as its oid prefix" do
    assert_equal "usr", User.oid_prefix
  end

  test "find_by_oid round-trips" do
    user = users(:acme_admin)
    assert_equal user, User.find_by_oid(user.oid)
  end

  test "status defaults to pending" do
    assert_equal "pending", User.new.status
  end

  test "rejects an unknown status" do
    user = User.new(valid_attrs(status: "bogus"))
    assert_not user.valid?
    assert_includes user.errors[:status], "is not included in the list"
  end

  test "approve! activates and records the approver" do
    user = User.create!(valid_attrs(email: "approve-me@example.com").except(:password))
    admin = users(:acme_admin)
    user.approve!(by: admin)
    assert user.reload.active?
    assert_equal admin, user.approved_by
    assert_not_nil user.approved_at
  end

  test "destroys linked identities" do
    user = User.create!(valid_attrs(email: "with-identity@example.com").except(:password))
    user.user_identities.create!(provider: "google", subject: "destroy-sub")
    assert_difference -> { UserIdentity.count }, -1 do
      user.destroy
    end
  end
end
