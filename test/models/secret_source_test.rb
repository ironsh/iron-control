require "test_helper"

class SecretSourceTest < ActiveSupport::TestCase
  test "env source is valid with var" do
    s = SecretSource.new(source_type: "env", config: { "var" => "FOO" })
    assert s.valid?
  end

  test "aws_sm source is valid with secret_id" do
    s = SecretSource.new(source_type: "aws_sm", config: { "secret_id" => "arn:..." })
    assert s.valid?
  end

  test "aws_ssm source is valid with name" do
    s = SecretSource.new(source_type: "aws_ssm", config: { "name" => "/prod/key" })
    assert s.valid?
  end

  test "1password source is valid with secret_ref" do
    s = SecretSource.new(source_type: "1password", config: { "secret_ref" => "op://v/i/f" })
    assert s.valid?
  end

  test "1password_connect source is valid with secret_ref" do
    s = SecretSource.new(source_type: "1password_connect", config: { "secret_ref" => "op://v/i/f" })
    assert s.valid?
  end

  test "universal json_key is allowed for all source types" do
    SecretSource::SOURCE_TYPES.each do |type|
      required = SecretSource::CONFIG_SCHEMA[type][:required]
      config = required.each_with_object({}) { |k, h| h[k] = "x" }
      config["json_key"] = "password"
      config["ttl"] = "5m"
      s = SecretSource.new(source_type: type, config: config)
      assert s.valid?, "expected #{type} with json_key+ttl to be valid, got: #{s.errors.full_messages.inspect}"
    end
  end

  test "requires source_type" do
    s = SecretSource.new(config: { "var" => "FOO" })
    assert_not s.valid?
    assert_includes s.errors[:source_type], "can't be blank"
  end

  test "rejects unknown source_type" do
    s = SecretSource.new(source_type: "vault", config: {})
    assert_not s.valid?
    assert_includes s.errors[:source_type], "is not included in the list"
  end

  test "missing required key produces config error per source_type" do
    SecretSource::CONFIG_SCHEMA.each do |type, schema|
      next if schema[:required].empty?
      s = SecretSource.new(source_type: type, config: {})
      assert_not s.valid?, "expected #{type} with empty config to be invalid"
      assert s.errors[:config].any? { |m| m.include?("missing required key") },
        "expected missing-key error for #{type}, got: #{s.errors[:config].inspect}"
    end
  end

  test "rejects unknown key in config" do
    s = SecretSource.new(source_type: "env", config: { "var" => "FOO", "bogus" => "x" })
    assert_not s.valid?
    assert s.errors[:config].any? { |m| m.include?("unknown key") }
  end

  test "source_type is immutable after creation" do
    s = secret_sources(:env_token)
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      s.update!(source_type: "aws_sm")
    end
  end

  test "config must be a hash" do
    s = SecretSource.new(source_type: "env", config: "not-a-hash")
    assert_not s.valid?
    assert_includes s.errors[:config], "must be a hash"
  end

  test "declares scs as its oid prefix" do
    assert_equal "scs", SecretSource.oid_prefix
  end

  test "find_by_oid round-trips" do
    s = secret_sources(:env_token)
    assert_equal s, SecretSource.find_by_oid(s.oid)
  end
end
