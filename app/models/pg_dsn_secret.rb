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

  # A Postgres GUC name: a bare identifier, or a dotted class.name custom
  # variable. Mirrors the proxy's validation so the control plane rejects names
  # the proxy would refuse to pin.
  GUC_NAME_FORMAT = /\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?\z/
  # role / session_authorization are managed via the role field and are always
  # blocked by the proxy's role policy; they may not appear as pinned settings.
  RESERVED_SETTING_NAMES = %w[role session_authorization].freeze

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
    entry["settings"] = proxy_settings if proxy_settings.present?
    entry
  end

  # The pinned session settings as the proxy expects them: an ordered array of
  # { "name", "value" } objects. Normalizes whatever shape was stored (string
  # keys, blank rows) into the canonical form, dropping entries without a name.
  def proxy_settings
    Array(settings).filter_map do |s|
      next unless s.is_a?(Hash)
      name = s["name"].presence || s[:name].presence
      next if name.blank?
      { "name" => name, "value" => (s["value"] || s[:value]).to_s }
    end
  end

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :database, presence: true, uniqueness: { scope: :namespace }
  validate :labels_is_a_hash
  validate :settings_are_valid
  validate :dsn_source_present
  validate :database_matches_inline_dsn

  private

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  # Settings must be an array of { name, value } objects with valid, unique GUC
  # names, mirroring the proxy's compileSettings so an upstream the proxy would
  # reject can't be saved here. Empty is fine (the default).
  def settings_are_valid
    unless settings.is_a?(Array)
      errors.add(:settings, "must be an array")
      return
    end
    seen = {}
    settings.each_with_index do |s, i|
      unless s.is_a?(Hash)
        errors.add(:settings, "[#{i}] must be an object")
        next
      end
      name = (s["name"] || s[:name]).to_s
      if name.blank?
        errors.add(:settings, "[#{i}] name is required")
        next
      end
      unless name.match?(GUC_NAME_FORMAT)
        errors.add(:settings, "[#{i}] invalid setting name #{name.inspect}")
        next
      end
      lower = name.downcase
      if RESERVED_SETTING_NAMES.include?(lower)
        errors.add(:settings, "[#{i}] #{name.inspect} is managed by the proxy; use the role field")
        next
      end
      if seen.key?(lower)
        errors.add(:settings, "duplicate setting #{name.inspect}")
        next
      end
      seen[lower] = true
    end
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
