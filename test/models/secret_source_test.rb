require "test_helper"

class SecretSourceTest < ActiveSupport::TestCase
  def new_source(attrs = {})
    SecretSource.new(attrs)
  end

  test "env source is valid with var" do
    s = new_source(source_type: "env", config: { "var" => "FOO" })
    assert s.valid?
  end

  test "aws_sm source is valid with secret_id" do
    s = new_source(source_type: "aws_sm", config: { "secret_id" => "arn:..." })
    assert s.valid?
  end

  test "aws_ssm source is valid with name" do
    s = new_source(source_type: "aws_ssm", config: { "name" => "/prod/key" })
    assert s.valid?
  end

  test "1password source is valid with secret_ref" do
    s = new_source(source_type: "1password", config: { "secret_ref" => "op://v/i/f" })
    assert s.valid?
  end

  test "1password_connect source is valid with secret_ref" do
    s = new_source(source_type: "1password_connect", config: { "secret_ref" => "op://v/i/f" })
    assert s.valid?
  end

  test "universal json_key is allowed for all source types" do
    SecretSource::SOURCE_TYPES.each do |type|
      required = SecretSource::CONFIG_SCHEMA[type][:required]
      config = required.each_with_object({}) { |k, h| h[k] = "x" }
      config["json_key"] = "password"
      config["ttl"] = "5m"
      attrs = { source_type: type, config: config }
      attrs[:secret] = "v" if type == "control_plane"
      s = new_source(attrs)
      assert s.valid?, "expected #{type} with json_key+ttl to be valid, got: #{s.errors.full_messages.inspect}"
    end
  end

  test "control_plane source is valid with a secret" do
    s = new_source(source_type: "control_plane", secret: "supersecret")
    assert s.valid?
  end

  test "control_plane source requires a secret" do
    s = new_source(source_type: "control_plane")
    assert_not s.valid?
    assert s.errors[:secret].any? { |m| m.include?("can't be blank") }
  end

  test "non-control_plane source rejects a secret" do
    s = new_source(source_type: "env", config: { "var" => "FOO" }, secret: "nope")
    assert_not s.valid?
    assert s.errors[:secret].any? { |m| m.include?("only allowed") }
  end

  test "control_plane source secret round-trips through encryption" do
    ref = static_secrets(:github_token_inject)
    s = SecretSource.create!(source_type: "control_plane", secret: "rotated-secret", static_secret: ref)
    assert_equal "rotated-secret", SecretSource.find(s.id).secret
    raw = SecretSource.connection.select_value("SELECT secret FROM secret_sources WHERE id = #{s.id}")
    assert_not_equal "rotated-secret", raw, "expected ciphertext, not plaintext, at rest"
  end

  test "requires source_type" do
    s = new_source(config: { "var" => "FOO" })
    assert_not s.valid?
    assert_includes s.errors[:source_type], "can't be blank"
  end

  test "rejects unknown source_type" do
    s = new_source(source_type: "vault", config: {})
    assert_not s.valid?
    assert_includes s.errors[:source_type], "is not included in the list"
  end

  test "missing required key produces config error per source_type" do
    SecretSource::CONFIG_SCHEMA.each do |type, schema|
      next if schema[:required].empty?
      s = new_source(source_type: type, config: {})
      assert_not s.valid?, "expected #{type} with empty config to be invalid"
      assert s.errors[:config].any? { |m| m.include?("missing required key") },
        "expected missing-key error for #{type}, got: #{s.errors[:config].inspect}"
    end
  end

  test "rejects unknown key in config" do
    s = new_source(source_type: "env", config: { "var" => "FOO", "bogus" => "x" })
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
    s = new_source(source_type: "env", config: "not-a-hash")
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

  test "token_broker source is valid with credential_id" do
    s = new_source(source_type: "token_broker", config: { "credential_id" => "shared" })
    assert s.valid?, s.errors.full_messages.inspect
  end

  test "token_broker source accepts failure_ttl" do
    s = new_source(source_type: "token_broker", config: { "credential_id" => "shared", "failure_ttl" => "30s" })
    assert s.valid?, s.errors.full_messages.inspect
  end

  test "token_broker source requires credential_id" do
    s = new_source(source_type: "token_broker", config: { "failure_ttl" => "30s" })
    assert_not s.valid?
    assert s.errors[:config].any? { |m| m.include?("credential_id") }
  end

  test "token_broker source maps through to_proxy_source" do
    s = new_source(source_type: "token_broker", config: { "credential_id" => "shared", "ttl" => "1m" })
    assert_equal({ "credential_id" => "shared", "ttl" => "1m", "type" => "token_broker" }, s.to_proxy_source)
  end

  test "rejects belonging to more than one owner" do
    s = new_source(source_type: "env", config: { "var" => "FOO" },
                   static_secret: static_secrets(:github_token_inject),
                   gcp_auth_secret: gcp_auth_secrets(:acme_bigquery))
    assert_not s.valid?
    assert_includes s.errors[:base], "must belong to at most one of static_secret, gcp_auth_secret, oauth_token_secret"
  end

  test "role is only allowed for an oauth_token_secret source" do
    s = new_source(source_type: "env", config: { "var" => "FOO" },
                   static_secret: static_secrets(:github_token_inject), role: "client_id")
    assert_not s.valid?
    assert_includes s.errors[:role], "is only allowed for an oauth_token_secret source"
  end

  test "role is required for an oauth_token_secret source" do
    s = new_source(source_type: "env", config: { "var" => "FOO" },
                   oauth_token_secret: oauth_token_secrets(:acme_gmail_oauth))
    assert_not s.valid?
    assert_includes s.errors[:role], "can't be blank for an oauth_token_secret source"
  end
end
