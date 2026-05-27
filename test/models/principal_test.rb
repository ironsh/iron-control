require "test_helper"

class PrincipalTest < ActiveSupport::TestCase
  test "is valid with namespace and foreign_id" do
    principal = Principal.new(namespace: "centaur", foreign_id: "C-new-1")
    assert principal.valid?
  end

  test "requires namespace" do
    principal = Principal.new(foreign_id: "C-new-1")
    assert_not principal.valid?
    assert_includes principal.errors[:namespace], "can't be blank"
  end

  test "requires foreign_id" do
    principal = Principal.new(namespace: "centaur")
    assert_not principal.valid?
    assert_includes principal.errors[:foreign_id], "can't be blank"
  end

  test "foreign_id is unique within a namespace" do
    existing = principals(:centaur_channel)
    dup = Principal.new(namespace: existing.namespace, foreign_id: existing.foreign_id)
    assert_not dup.valid?
    assert_includes dup.errors[:foreign_id], "has already been taken"
  end

  test "same foreign_id is allowed across different namespaces" do
    existing = principals(:centaur_channel)
    other = Principal.new(namespace: "traceforce", foreign_id: existing.foreign_id)
    assert other.valid?
  end

  test "labels defaults to empty hash" do
    principal = Principal.create!(namespace: "centaur", foreign_id: "C-default-labels")
    assert_equal({}, principal.reload.labels)
  end

  test "labels accepts arbitrary string map" do
    principal = Principal.create!(
      namespace: "centaur",
      foreign_id: "C-labels",
      labels: { "env" => "prod", "team" => "platform" }
    )
    assert_equal({ "env" => "prod", "team" => "platform" }, principal.reload.labels)
  end

  test "namespace and foreign_id are immutable after creation" do
    principal = principals(:centaur_channel)
    original_namespace = principal.namespace
    original_foreign_id = principal.foreign_id

    principal.update!(namespace: "other", foreign_id: "C-other", labels: { "changed" => "yes" })
    principal.reload

    assert_equal original_namespace, principal.namespace
    assert_equal original_foreign_id, principal.foreign_id
    assert_equal({ "changed" => "yes" }, principal.labels)
  end

  test "oid returns prn-prefixed encoded id" do
    principal = principals(:centaur_channel)
    oid = principal.oid
    assert_match(/\Aprn_[A-Za-z0-9]+\z/, oid)
    assert_operator oid.length, :>=, "prn_".length + OpaqueId::MIN_LENGTH
  end

  test "oid is nil for unpersisted records" do
    assert_nil Principal.new(namespace: "centaur", foreign_id: "x").oid
  end

  test "find_by_oid round-trips" do
    principal = principals(:centaur_channel)
    assert_equal principal, Principal.find_by_oid(principal.oid)
  end

  test "find_by_oid returns nil for malformed input" do
    assert_nil Principal.find_by_oid(nil)
    assert_nil Principal.find_by_oid("")
    assert_nil Principal.find_by_oid("not-a-prn")
    assert_nil Principal.find_by_oid("prn_")
    assert_nil Principal.find_by_oid("prn_!!!invalid!!!")
  end

  test "find_by_oid rejects wrong prefix" do
    principal = principals(:centaur_channel)
    encoded = principal.oid.delete_prefix("prn_")
    assert_nil Principal.find_by_oid("grant_#{encoded}")
  end

  test "find_by_oid! raises on miss" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Principal.find_by_oid!("prn_doesnotexist")
    end
  end

  test "decode_oid rejects non-canonical encodings" do
    principal = principals(:centaur_channel)
    canonical = principal.oid.delete_prefix("prn_")
    # Sqids can decode some non-canonical inputs to the same number; we require canonical form.
    longer = canonical + canonical[0]
    assert_nil Principal.decode_oid("prn_#{longer}") if Principal.oid_encoder.decode(longer) == [ principal.id ]
  end

  test "oid_prefix raises NotImplementedError when not declared" do
    klass = Class.new(ApplicationRecord) { self.table_name = "principals" }
    assert_raises(NotImplementedError) { klass.oid_prefix }
  end
end
