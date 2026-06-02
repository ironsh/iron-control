require "test_helper"

class PgDsnSecretTest < ActiveSupport::TestCase
  def base_attrs(overrides = {})
    {
      namespace: "acme",
      foreign_id: "new-pg",
      created_by: users(:acme_admin)
    }.merge(overrides)
  end

  def with_dsn(secret = nil)
    secret ||= PgDsnSecret.new(base_attrs)
    secret.dsn_source = SecretSource.new(source_type: "env", config: { "var" => "PG_DSN" })
    secret
  end

  test "is valid with a dsn source" do
    assert with_dsn.valid?
  end

  test "requires a dsn source" do
    secret = PgDsnSecret.new(base_attrs)
    assert_not secret.valid?
    assert_includes secret.errors[:dsn_source], "can't be blank"
  end

  test "requires a foreign_id (it is the proxy's binding key)" do
    secret = with_dsn(PgDsnSecret.new(base_attrs(foreign_id: nil)))
    assert_not secret.valid?
    assert_includes secret.errors[:foreign_id], "can't be blank"
  end

  test "role is optional" do
    assert with_dsn(PgDsnSecret.new(base_attrs(role: nil))).valid?
  end

  test "foreign_id is unique within a namespace" do
    with_dsn(PgDsnSecret.new(base_attrs(foreign_id: "shared-pg"))).save!
    dup = with_dsn(PgDsnSecret.new(base_attrs(foreign_id: "shared-pg")))
    assert_not dup.valid?
    assert_includes dup.errors[:foreign_id], "has already been taken"
  end

  test "to_proxy_dsn keys the entry by foreign_id and carries the dsn source and role" do
    secret = pg_dsn_secrets(:acme_analytics_pg)
    entry = secret.to_proxy_dsn

    assert_equal secret.oid, entry["id"]
    assert_equal secret.foreign_id, entry["foreign_id"]
    assert_equal({ "type" => "env", "var" => "PG_ANALYTICS_DSN" }, entry["dsn"])
    assert_equal "readonly", entry["role"]
  end

  test "to_proxy_dsn omits role when blank" do
    entry = pg_dsn_secrets(:acme_reporting_pg).to_proxy_dsn
    refute entry.key?("role")
    assert_equal "aws_sm", entry.dig("dsn", "type")
  end

  test "declares pgs as its oid prefix" do
    assert_equal "pgs", PgDsnSecret.oid_prefix
  end
end
