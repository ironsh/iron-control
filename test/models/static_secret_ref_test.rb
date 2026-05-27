require "test_helper"

class StaticSecretRefTest < ActiveSupport::TestCase
  def valid_inject_attrs(overrides = {})
    {
      namespace: "acme",
      name: "new-ref",
      inject_config: { "header" => "Authorization", "formatter" => "Bearer {{ .Value }}" }
    }.merge(overrides)
  end

  def valid_replace_attrs(overrides = {})
    {
      namespace: "acme",
      name: "new-ref",
      replace_config: { "proxy_value" => "__TOKEN__" }
    }.merge(overrides)
  end

  test "is valid with inject_config" do
    assert StaticSecretRef.new(valid_inject_attrs).valid?
  end

  test "is valid with replace_config" do
    assert StaticSecretRef.new(valid_replace_attrs).valid?
  end

  test "requires namespace" do
    ref = StaticSecretRef.new(valid_inject_attrs(namespace: nil))
    assert_not ref.valid?
    assert_includes ref.errors[:namespace], "can't be blank"
  end

  test "requires name" do
    ref = StaticSecretRef.new(valid_inject_attrs(name: nil))
    assert_not ref.valid?
    assert_includes ref.errors[:name], "can't be blank"
  end

  test "name is unique within a namespace" do
    existing = static_secret_refs(:github_token_inject)
    dup = StaticSecretRef.new(valid_inject_attrs(namespace: existing.namespace, name: existing.name))
    assert_not dup.valid?
    assert_includes dup.errors[:name], "has already been taken"
  end

  test "same name is allowed across different namespaces" do
    existing = static_secret_refs(:github_token_inject)
    other = StaticSecretRef.new(valid_inject_attrs(namespace: "globex", name: existing.name))
    assert other.valid?
  end

  test "name accepts letters, numbers, underscores, and hyphens" do
    assert StaticSecretRef.new(valid_inject_attrs(name: "Abc_123-xyz")).valid?
  end

  test "name rejects disallowed characters" do
    %w[has.dot has/slash has\ space ümlaut].each do |bad|
      ref = StaticSecretRef.new(valid_inject_attrs(name: bad))
      assert_not ref.valid?, "expected #{bad.inspect} to be invalid"
      assert ref.errors[:name].any? { |m| m.include?("may only contain") }
    end
  end

  test "labels defaults to empty hash" do
    ref = StaticSecretRef.create!(valid_inject_attrs(name: "default-labels"))
    assert_equal({}, ref.reload.labels)
  end

  test "must define one of inject_config or replace_config" do
    ref = StaticSecretRef.new(namespace: "acme", name: "neither")
    assert_not ref.valid?
    assert_includes ref.errors[:base], "must define one of inject_config or replace_config"
  end

  test "cannot define both inject_config and replace_config" do
    ref = StaticSecretRef.new(
      namespace: "acme",
      name: "both",
      inject_config: { "header" => "Authorization" },
      replace_config: { "proxy_value" => "__TOKEN__" }
    )
    assert_not ref.valid?
    assert_includes ref.errors[:base], "inject_config and replace_config are mutually exclusive"
  end

  test "inject_config requires exactly one of header or query_param" do
    ref = StaticSecretRef.new(valid_inject_attrs(inject_config: { "formatter" => "x" }))
    assert_not ref.valid?
    assert ref.errors[:inject_config].any?
  end

  test "inject_config with query_param is valid" do
    ref = StaticSecretRef.new(valid_inject_attrs(inject_config: { "query_param" => "api_key" }))
    assert ref.valid?, ref.errors.full_messages.inspect
  end

  test "inject_config rejects header and query_param together" do
    ref = StaticSecretRef.new(valid_inject_attrs(
      inject_config: { "header" => "Authorization", "query_param" => "api_key" }
    ))
    assert_not ref.valid?
    assert ref.errors[:inject_config].any?
  end

  test "inject_config rejects unknown keys" do
    ref = StaticSecretRef.new(valid_inject_attrs(
      inject_config: { "header" => "Authorization", "bogus" => "x" }
    ))
    assert_not ref.valid?
    assert ref.errors[:inject_config].any?
  end

  test "replace_config requires proxy_value" do
    ref = StaticSecretRef.new(valid_replace_attrs(replace_config: { "match_body" => true }))
    assert_not ref.valid?
    assert ref.errors[:replace_config].any?
  end

  test "replace_config rejects unknown keys" do
    ref = StaticSecretRef.new(valid_replace_attrs(
      replace_config: { "proxy_value" => "x", "bogus" => true }
    ))
    assert_not ref.valid?
    assert ref.errors[:replace_config].any?
  end

  test "replace_config rejects non-boolean match flags" do
    ref = StaticSecretRef.new(valid_replace_attrs(
      replace_config: { "proxy_value" => "x", "match_body" => "yes" }
    ))
    assert_not ref.valid?
    assert ref.errors[:replace_config].any?
  end

  test "labels must be a hash" do
    ref = StaticSecretRef.new(valid_inject_attrs(labels: "nope"))
    assert_not ref.valid?
    assert_includes ref.errors[:labels], "must be a hash"
  end

  test "has_one source association" do
    ref = static_secret_refs(:github_token_inject)
    src = SecretSource.create!(source_type: "env", config: { "var" => "GITHUB_TOKEN" }, static_secret_ref: ref)
    assert_equal src, ref.reload.source
  end

  test "has_many rules association" do
    ref = static_secret_refs(:github_token_inject)
    r1 = RequestRule.create!(host: "api.github.com", static_secret_ref: ref)
    r2 = RequestRule.create!(host: "api.example.com", static_secret_ref: ref, position: 1)
    assert_equal [ r1, r2 ], ref.reload.rules.to_a
  end

  test "declares ssr as its oid prefix" do
    assert_equal "ssr", StaticSecretRef.oid_prefix
  end

  test "find_by_oid round-trips" do
    ref = static_secret_refs(:github_token_inject)
    assert_equal ref, StaticSecretRef.find_by_oid(ref.oid)
  end
end
