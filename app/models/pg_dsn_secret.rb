# A Postgres upstream credential: a connection-string (DSN) resolved from a
# secret source, plus an optional SET ROLE for the upstream session. Delivered
# to iron-proxy keyed by foreign_id; the proxy's local config defines the actual
# listener (bind address, client auth) and binds it to this secret by foreign_id
# via an env var. Because that binding key must exist, foreign_id is required
# here (unlike the other secret types, which are not bound by a host-side
# reference). The listener/client knobs are deliberately not modeled — they are
# proxy-host deployment concerns, like the gcp_auth keyfile_path the control
# plane also declines to own. There are no request rules: a Postgres listener
# matches by port, not by request.
class PgDsnSecret < ApplicationRecord
  oid_prefix "pgs"

  include ForeignIdCollisionGuard

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  has_one :dsn_source, class_name: "SecretSource", dependent: :destroy
  has_many :grants, dependent: :destroy
  belongs_to :created_by, class_name: "User"

  # One entry in the proxy's synced `postgres` list. A proxy-local listener binds
  # to it by foreign_id (via its foreign_id_env); the opaque id is carried too so
  # the proxy can refer back to the canonical resource. The DSN reuses the shared
  # secrets source shape.
  def to_proxy_dsn
    entry = { "id" => oid, "foreign_id" => foreign_id, "dsn" => dsn_source&.to_proxy_source }
    entry["database"] = database if database.present?
    entry["role"] = role if role.present?
    entry
  end

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validate :labels_is_a_hash
  validate :dsn_source_present

  private

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  def dsn_source_present
    errors.add(:dsn_source, "can't be blank") if dsn_source.blank?
  end
end
