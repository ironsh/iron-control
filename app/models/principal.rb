class Principal < ApplicationRecord
  oid_prefix "prn"

  include ForeignIdCollisionGuard

  attr_readonly :namespace, :foreign_id

  has_many :grants, dependent: :destroy
  # Proxies outlive their principal: deleting a principal unassigns its proxies
  # rather than destroying them, leaving them ready for reassignment.
  has_many :proxies, dependent: :nullify
  has_many :principal_roles, dependent: :destroy
  has_many :roles, through: :principal_roles
  belongs_to :created_by, class_name: "User"

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, uniqueness: { scope: :namespace, allow_nil: true },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }, allow_nil: true

  # Stand-in for an inline secret value in redacted config: effective_config
  # reports that a control_plane source carries a value without revealing it.
  REDACTED = "[redacted]".freeze

  # Every grant this principal resolves to: its own direct grants plus the
  # grants of every role it is assigned. Secrets reachable through more than one
  # path collapse naturally because callers select distinct secret rows.
  def effective_grants
    Grant.where(principal_id: id).or(Grant.where(role_id: role_ids))
  end

  # Static secrets this principal resolves to, via its effective grants.
  def granted_static_secrets
    StaticSecret
      .where(id: effective_grants.select(:static_secret_id))
      .includes(:source, :rules)
      .order(:id)
  end

  # gcp_auth credentials this principal resolves to, via its effective grants.
  def granted_gcp_auth_secrets
    GcpAuthSecret
      .where(id: effective_grants.select(:gcp_auth_secret_id))
      .includes(:keyfile_source, :rules)
      .order(:id)
  end

  # oauth_token credentials this principal resolves to, via its effective grants.
  def granted_oauth_token_secrets
    OauthTokenSecret
      .where(id: effective_grants.select(:oauth_token_secret_id))
      .includes(:sources, :rules)
      .order(:id)
  end

  # Postgres upstreams this principal resolves to, via its effective grants.
  def granted_pg_dsn_secrets
    PgDsnSecret
      .where(id: effective_grants.select(:pg_dsn_secret_id))
      .includes(:dsn_source)
      .order(:id)
  end

  # The `secrets` array delivered to iron-proxy. Each entry maps to the proxy's
  # `secrets` transform `secretEntry` shape. Secrets without a source are skipped
  # because the proxy requires a source to resolve a value.
  def sync_secrets
    granted_static_secrets.filter_map do |ss|
      next unless ss.source
      ss.to_proxy_secret
    end
  end

  # The `transforms` array delivered to iron-proxy: one gcp_auth transform per
  # granted GcpAuthSecret, plus a single oauth_token transform bundling every
  # granted OauthTokenSecret as one `tokens` entry.
  def sync_transforms
    transforms = granted_gcp_auth_secrets.map(&:to_proxy_transform)

    oauth_entries = granted_oauth_token_secrets.map(&:to_proxy_entry)
    transforms << { "name" => "oauth_token", "config" => { "tokens" => oauth_entries } } if oauth_entries.any?

    transforms
  end

  # The top-level `postgres` array delivered to iron-proxy: one DSN entry per
  # granted PgDsnSecret, keyed by foreign_id. Entries without a DSN source are
  # skipped because the proxy can't dial an upstream without one.
  def sync_postgres
    granted_pg_dsn_secrets.filter_map do |pg|
      next unless pg.dsn_source
      pg.to_proxy_dsn
    end
  end

  # The config this principal resolves to, in the same shape iron-proxy receives
  # on /sync, but for operator inspection rather than delivery: when
  # `redact_secrets` is set (the default), inline control_plane source values are
  # replaced with REDACTED. Every other source type carries a reference (an env
  # var name, a secret_id, ...) that is configuration, not a live credential, so
  # it passes through untouched.
  def effective_config(redact_secrets: true)
    config = {
      "secrets" => sync_secrets,
      "transforms" => sync_transforms,
      "postgres" => sync_postgres
    }
    redact_secrets ? self.class.redact_live_secrets(config) : config
  end

  # Deep-walk a config payload and blank out the inline value of every
  # control_plane source, leaving the rest of the structure intact.
  def self.redact_live_secrets(value)
    case value
    when Hash
      redacted = value.transform_values { |v| redact_live_secrets(v) }
      redacted["value"] = REDACTED if redacted["type"] == "control_plane" && redacted.key?("value")
      redacted
    when Array
      value.map { |v| redact_live_secrets(v) }
    else
      value
    end
  end
end
