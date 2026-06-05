# Operator console: a lightweight, server-rendered HTML view over principals,
# their effective grants, and secrets. Read-only; gated behind a console session
# via ApplicationController#require_login. Distinct from the JSON API.
class ConsoleController < ApplicationController
  layout "console"

  # The four grantable secret kinds, keyed by a short slug used in the UI. The
  # `includes` association is eager-loaded so the source/injection columns don't
  # trigger a query per row.
  SECRET_KINDS = {
    "static" => { model: StaticSecret, label: "Static", includes: :source },
    "gcp_auth" => { model: GcpAuthSecret, label: "GCP Auth", includes: :keyfile_source },
    "oauth_token" => { model: OauthTokenSecret, label: "OAuth Token", includes: :sources },
    "pg_dsn" => { model: PgDsnSecret, label: "Postgres DSN", includes: :dsn_source },
    "hmac" => { model: HmacSecret, label: "HMAC", includes: :sources }
  }.freeze

  # The config key that carries a source's human-meaningful reference, per
  # source_type. control_plane keeps its value inline (and redacted), so it has
  # no reference key.
  SOURCE_REF_KEYS = {
    "env" => "var", "aws_sm" => "secret_id", "aws_ssm" => "name",
    "1password" => "secret_ref", "1password_connect" => "secret_ref",
    "token_broker" => "credential_id"
  }.freeze

  def principals
    @principals = Principal.order(created_at: :asc, id: :asc)
  end

  def principal
    @principal = Principal.find_by_oid!(params[:id])
    @roles = @principal.roles.order(:id)
    @granted = {
      "static" => @principal.granted_static_secrets,
      "gcp_auth" => @principal.granted_gcp_auth_secrets,
      "oauth_token" => @principal.granted_oauth_token_secrets,
      "pg_dsn" => @principal.granted_pg_dsn_secrets,
      "hmac" => @principal.granted_hmac_secrets
    }
  rescue ActiveRecord::RecordNotFound
    render plain: "principal not found", status: :not_found
  end

  def secrets
    @secrets_by_kind = SECRET_KINDS.transform_values do |cfg|
      cfg[:model].includes(cfg[:includes]).order(created_at: :asc, id: :asc)
    end
  end

  # Managed broker credentials and their refresh-loop status. Distinct from
  # SECRET_KINDS because a broker credential is not grantable -- it is referenced
  # by a token_broker source rather than granted directly.
  def credentials
    @credentials = BrokerCredential.order(created_at: :asc, id: :asc)
  end

  helper_method :secret_kind_label
  def secret_kind_label(slug)
    SECRET_KINDS.dig(slug, :label) || slug
  end

  # Where a secret's value is resolved from, as a "source_type:reference" label
  # (e.g. "env:STRIPE_KEY", "aws_sm:prod/db"). nil when the secret has no source.
  helper_method :secret_source_ref
  def secret_source_ref(record)
    case record
    when StaticSecret then source_label(record.source)
    when PgDsnSecret   then source_label(record.dsn_source)
    when GcpAuthSecret
      record.keyfile_source ? source_label(record.keyfile_source) : provider_label(record.credentials_provider)
    when OauthTokenSecret
      fields = record.sources.select(&:credential_field?).sort_by(&:role)
      labels = fields.map { |s| "#{s.role}=#{source_label(s)}" }
      labels.presence&.join("  ·  ")
    when HmacSecret
      fields = record.sources.sort_by(&:role)
      labels = fields.map { |s| "#{s.role}=#{source_label(s)}" }
      labels.presence&.join("  ·  ")
    end
  end

  # The request header (or other target) the resolved secret is injected into.
  # nil when the secret isn't request-header injected (e.g. a Postgres DSN,
  # matched by listener port rather than by request).
  helper_method :secret_injection
  def secret_injection(record)
    case record
    when StaticSecret  then static_injection(record)
    when GcpAuthSecret  then "Authorization: Bearer"
    when OauthTokenSecret
      header = record.header.presence || "Authorization"
      prefix = record.value_prefix.presence&.strip
      prefix ? "#{header}: #{prefix} …" : header
    when HmacSecret
      names = Array(record.headers).filter_map { |h| h["name"].presence if h.is_a?(Hash) }
      names.presence&.join(", ")
    when PgDsnSecret then nil
    end
  end

  private

  def source_label(source)
    return nil unless source

    key = SOURCE_REF_KEYS[source.source_type]
    detail =
      if key && source.config.is_a?(Hash)
        source.config[key]
      elsif source.source_type == "control_plane"
        "inline"
      end

    detail.present? ? "#{source.source_type}:#{detail}" : source.source_type
  end

  def provider_label(provider)
    return nil unless provider.is_a?(Hash) && provider["type"].present?
    provider["type"]
  end

  def static_injection(record)
    if record.inject_config.present?
      cfg = record.inject_config
      return cfg["header"] if cfg["header"].present?
      return "?#{cfg["query_param"]}" if cfg["query_param"].present?
    elsif record.replace_config.present?
      headers = Array(record.replace_config["match_headers"])
      return headers.any? ? "replace → #{headers.join(", ")}" : "replace"
    end
    nil
  end
end
