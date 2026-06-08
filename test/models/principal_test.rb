require "test_helper"

class PrincipalTest < ActiveSupport::TestCase
  def default_attrs(overrides = {})
    { created_by: users(:acme_admin) }.merge(overrides)
  end

  test "is valid with namespace and foreign_id" do
    principal = Principal.new(default_attrs(namespace: "acme", foreign_id: "C-new-1"))
    assert principal.valid?
  end

  test "namespace defaults to 'default'" do
    principal = Principal.new(default_attrs)
    assert_equal "default", principal.namespace
    assert principal.valid?
  end

  test "is valid with only a name" do
    assert Principal.new(default_attrs(name: "Just a label")).valid?
  end

  test "rejects a foreign_id that starts with the opaque id prefix" do
    principal = Principal.new(default_attrs(namespace: "acme", foreign_id: "prn_abc123"))
    assert_not principal.valid?
    assert_includes principal.errors[:foreign_id], "must not start with \"prn_\", which is reserved for opaque ids"
  end

  test "is invalid when namespace is blank" do
    principal = Principal.new(default_attrs(namespace: "", foreign_id: "C-blank"))
    assert_not principal.valid?
    assert_includes principal.errors[:namespace], "can't be blank"
  end

  test "foreign_id is unique within a namespace" do
    existing = principals(:acme_channel)
    dup = Principal.new(default_attrs(namespace: existing.namespace, foreign_id: existing.foreign_id))
    assert_not dup.valid?
    assert_includes dup.errors[:foreign_id], "has already been taken"
  end

  test "same foreign_id is allowed across different namespaces" do
    existing = principals(:acme_channel)
    other = Principal.new(default_attrs(namespace: "globex", foreign_id: existing.foreign_id))
    assert other.valid?
  end

  test "labels defaults to empty hash" do
    principal = Principal.create!(default_attrs(namespace: "acme", foreign_id: "C-default-labels"))
    assert_equal({}, principal.reload.labels)
  end

  test "labels accepts arbitrary string map" do
    principal = Principal.create!(default_attrs(
      namespace: "acme",
      foreign_id: "C-labels",
      labels: { "env" => "prod", "team" => "platform" }
    ))
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

  test "name is editable after creation" do
    principal = principals(:acme_channel)
    principal.update!(name: "Acme Slack channel")
    assert_equal "Acme Slack channel", principal.reload.name
  end

  test "declares prn as its oid prefix" do
    assert_equal "prn", Principal.oid_prefix
  end

  test "requires created_by" do
    principal = Principal.new(namespace: "acme", foreign_id: "C-needs-key")
    assert_not principal.valid?
    assert_includes principal.errors[:created_by], "must exist"
  end

  test "destroying a principal unassigns its proxies rather than destroying them" do
    principal = principals(:acme_channel)
    proxy = proxies(:acme_proxy)
    assert_equal principal, proxy.principal

    assert_no_difference -> { Proxy.count } do
      principal.destroy!
    end

    proxy.reload
    assert_nil proxy.principal
    assert_equal "unassigned", proxy.status
  end

  # --- effective config / grant resolution --------------------------------

  def principal_with_grants(*grantables)
    principal = principals(:globex_user)
    grantables.each do |g|
      key = Grant::GRANTABLE_ASSOCIATIONS.find { |a| g.is_a?(a.to_s.camelize.constantize) }
      Grant.create!(principal: principal, key => g, created_by: users(:globex_admin))
    end
    principal
  end

  test "sync_secrets delivers a brokered token inline and omits it until minted" do
    cred = BrokerCredential.create!(namespace: "default", foreign_id: "sync-#{SecureRandom.hex(4)}",
                                    token_endpoint: "https://idp.example/token", client_id: "cid",
                                    created_by: users(:globex_admin), refresh_token: "seed")

    secret = StaticSecret.new(namespace: "default", foreign_id: "brokered-#{SecureRandom.hex(4)}",
                              inject_config: { "header" => "Authorization" }, created_by: users(:globex_admin))
    secret.build_source(source_type: "token_broker", config: { "credential_id" => cred.oid })
    secret.rules.build(host: "api.example.com", position: 0)
    secret.save!

    principal = principal_with_grants(secret)

    # Bootstrapping (no token yet) -> the secret is omitted from sync entirely.
    assert_empty principal.sync_secrets

    # Once control mints a token, it is delivered inline like a control_plane value.
    cred.update!(access_token: "live-token", expires_at: 1.hour.from_now, last_refresh: Time.current)
    secrets = principal.sync_secrets
    assert_equal 1, secrets.length
    assert_equal({ "type" => "control_plane", "value" => "live-token" }, secrets.first["source"])

    # ...and redacted in the operator inspection view (no special-casing needed).
    assert_equal "[redacted]", principal.effective_config.dig("secrets", 0, "source", "value")
  end

  test "sync_transforms emits a gcp_auth transform per granted GcpAuthSecret" do
    transforms = principal_with_grants(gcp_auth_secrets(:acme_bigquery)).sync_transforms
    assert_equal 1, transforms.length
    assert_equal "gcp_auth", transforms.first["name"]
    assert_equal({ "type" => "workload_identity" }, transforms.first.dig("config", "credentials_provider"))
  end

  test "sync_transforms emits an aws_auth transform per granted AwsAuthSecret" do
    transforms = principal_with_grants(aws_auth_secrets(:acme_cloudwatch_aws)).sync_transforms
    aws = transforms.find { |t| t["name"] == "aws_auth" }
    refute_nil aws
    assert_equal({ "type" => "env", "var" => "AWS_ACCESS_KEY_ID" }, aws.dig("config", "access_key_id"))
    assert_equal({ "type" => "env", "var" => "AWS_SECRET_ACCESS_KEY" }, aws.dig("config", "secret_access_key"))
    assert_equal %w[logs monitoring], aws.dig("config", "allowed_services")
    assert_equal 1, aws.dig("config", "rules").length
  end

  test "sync_transforms bundles all granted oauth tokens into one transform" do
    transforms = principal_with_grants(oauth_token_secrets(:acme_gmail_oauth)).sync_transforms
    oauth = transforms.find { |t| t["name"] == "oauth_token" }
    refute_nil oauth
    tokens = oauth.dig("config", "tokens")
    assert_equal 1, tokens.length
    assert_equal "refresh_token", tokens.first["grant"]
  end

  test "sync_transforms is empty without transform grants" do
    assert_empty principals(:globex_user).sync_transforms
  end

  test "sync_postgres emits a DSN entry per granted PgDsnSecret, keyed by foreign_id" do
    entries = principal_with_grants(pg_dsn_secrets(:acme_analytics_pg)).sync_postgres
    assert_equal 1, entries.length
    assert_equal pg_dsn_secrets(:acme_analytics_pg).foreign_id, entries.first["foreign_id"]
    assert_equal({ "type" => "env", "var" => "PG_ANALYTICS_DSN" }, entries.first["dsn"])
  end

  test "sync_postgres is empty without pg_dsn grants" do
    assert_empty principals(:globex_user).sync_postgres
  end

  test "granted_static_secrets includes secrets granted via an assigned role" do
    # acme_channel holds the acme_infra role, which is granted acme_prod_api_key.
    assert_includes principals(:acme_channel).granted_static_secrets, static_secrets(:acme_prod_api_key)
  end

  test "effective grants dedupe a secret reachable both directly and via a role" do
    principal = principals(:acme_channel)
    # acme_prod_api_key already reaches the principal through the acme_infra role;
    # also grant it directly and confirm it still appears exactly once.
    Grant.create!(principal: principal, static_secret: static_secrets(:acme_prod_api_key),
                  created_by: users(:acme_admin))
    ids = principal.granted_static_secrets.map(&:id)
    assert_equal ids.uniq, ids
    assert_equal 1, ids.count(static_secrets(:acme_prod_api_key).id)
  end

  test "effective_config redacts inline control_plane values by default but not when asked for live secrets" do
    principal = principals(:acme_channel)
    SecretSource.create!(source_type: "control_plane", secret: "s3cr3t",
                         static_secret: static_secrets(:db_password_replace))

    redacted = principal.effective_config.fetch("secrets").find { |s| s.dig("source", "type") == "control_plane" }
    assert_equal "[redacted]", redacted.dig("source", "value")

    live = principal.effective_config(redact_secrets: false)
                    .fetch("secrets").find { |s| s.dig("source", "type") == "control_plane" }
    assert_equal "s3cr3t", live.dig("source", "value")
  end
end
