require "test_helper"

class PrincipalTest < ActiveSupport::TestCase
  test "is valid with namespace and foreign_id" do
    principal = Principal.new(namespace: "acme", foreign_id: "C-new-1")
    assert principal.valid?
  end

  test "requires namespace" do
    principal = Principal.new(foreign_id: "C-new-1")
    assert_not principal.valid?
    assert_includes principal.errors[:namespace], "can't be blank"
  end

  test "requires foreign_id" do
    principal = Principal.new(namespace: "acme")
    assert_not principal.valid?
    assert_includes principal.errors[:foreign_id], "can't be blank"
  end

  test "foreign_id is unique within a namespace" do
    existing = principals(:acme_channel)
    dup = Principal.new(namespace: existing.namespace, foreign_id: existing.foreign_id)
    assert_not dup.valid?
    assert_includes dup.errors[:foreign_id], "has already been taken"
  end

  test "same foreign_id is allowed across different namespaces" do
    existing = principals(:acme_channel)
    other = Principal.new(namespace: "globex", foreign_id: existing.foreign_id)
    assert other.valid?
  end

  test "labels defaults to empty hash" do
    principal = Principal.create!(namespace: "acme", foreign_id: "C-default-labels")
    assert_equal({}, principal.reload.labels)
  end

  test "labels accepts arbitrary string map" do
    principal = Principal.create!(
      namespace: "acme",
      foreign_id: "C-labels",
      labels: { "env" => "prod", "team" => "platform" }
    )
    assert_equal({ "env" => "prod", "team" => "platform" }, principal.reload.labels)
  end

  test "namespace is immutable after creation" do
    principal = principals(:acme_channel)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      principal.update!(namespace: "other")
    end
  end

  test "foreign_id is immutable after creation" do
    principal = principals(:acme_channel)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      principal.update!(foreign_id: "C-other")
    end
  end

  test "labels remain mutable after creation" do
    principal = principals(:acme_channel)
    principal.update!(labels: { "changed" => "yes" })
    assert_equal({ "changed" => "yes" }, principal.reload.labels)
  end

  test "declares prn as its oid prefix" do
    assert_equal "prn", Principal.oid_prefix
  end
end
