# A Postgres upstream credential: a connection-string (DSN) resolved from a
# secret source, plus an optional SET ROLE for the upstream session. Delivered to
# iron-proxy in the single-listener `postgres` list, where it is keyed for routing
# by `database` (the dbname a client sends to reach this upstream). `database` is
# therefore required and must match the database the DSN connects to; iron-control
# enforces that match where the DSN is inspectable (control_plane/inline) and
# documents it otherwise (the proxy returns FATAL 3D000 on a mismatch).
#
# `foreign_id` is also required: it identifies the upstream for credential
# delivery (env-var supplied DSNs) and is the stable handle operators reference.
# The listener bind address and client auth remain proxy-host deployment concerns
# and are not modeled here.
class PgDsnSecret < ApplicationRecord
  oid_prefix "pgs"

  include ForeignIdCollisionGuard

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  has_one :dsn_source, class_name: "SecretSource", dependent: :destroy
  has_many :grants, dependent: :destroy
  belongs_to :created_by, class_name: "User"

  # One entry in the proxy's synced `postgres` list, keyed for routing by
  # `database`. The opaque id is carried too so the proxy can refer back to the
  # canonical resource (it ignores fields it does not use). The DSN reuses the
  # shared secrets source shape.
  def to_proxy_dsn
    entry = {
      "id" => oid,
      "foreign_id" => foreign_id,
      "database" => database,
      "dsn" => dsn_source&.to_proxy_source
    }
    entry["role"] = role if role.present?
    entry
  end

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :database, presence: true, uniqueness: { scope: :namespace }
  validate :labels_is_a_hash
  validate :dsn_source_present
  validate :database_matches_inline_dsn

  private

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  def dsn_source_present
    errors.add(:dsn_source, "can't be blank") if dsn_source.blank?
  end

  # Enforce the spec invariant database == the DSN's database, but only where the
  # DSN is inspectable: a control_plane (inline) source. Other source types
  # resolve their value on the proxy host, so the proxy is the authority there.
  def database_matches_inline_dsn
    return if database.blank? # presence handles the empty case
    src = dsn_source
    return unless src&.source_type == "control_plane"
    dsn = inline_dsn_value(src)
    return if dsn.blank?

    begin
      parsed = PG::Connection.conninfo_parse(dsn)
    rescue PG::Error
      return # malformed inline DSN: let the proxy be the authority
    end

    named = parsed.find { |o| o[:keyword] == "dbname" }&.dig(:val)
    if named.blank?
      errors.add(:database, "DSN names no database; it must match #{database.inspect}")
    elsif named != database
      errors.add(:database, "must match the DSN database (#{named.inspect})")
    end
  end

  # The literal DSN string a control_plane source resolves to, honoring json_key
  # the way the proxy would (parse JSON, then extract the key). Returns nil when
  # the value can't be inspected.
  def inline_dsn_value(src)
    key = src.config.is_a?(Hash) ? src.config["json_key"] : nil
    return src.secret if key.blank?
    JSON.parse(src.secret.to_s)[key]
  rescue JSON::ParserError, TypeError
    nil
  end
end
