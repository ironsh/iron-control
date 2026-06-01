class Proxy < ApplicationRecord
  oid_prefix "prx"

  TOKEN_PREFIX = "iprx_".freeze
  TOKEN_FORMAT = /\Aiprx_[0-9a-f]{64}\z/

  attr_readonly :principal_id, :bearer_token_hash
  attr_accessor :token

  belongs_to :principal

  validates :name, presence: true
  validates :bearer_token_hash, presence: true, uniqueness: true
  validate :token_matches_format, on: :create

  before_validation :issue_token, on: :create

  def self.find_by_token(plaintext)
    return nil if plaintext.blank?
    find_by(bearer_token_hash: hash_token(plaintext))
  end

  def self.hash_token(plaintext)
    Digest::SHA256.hexdigest(plaintext)
  end

  # Static secrets this proxy may receive, via its principal's grants.
  def granted_static_secrets
    StaticSecret
      .where(id: principal.grants.select(:static_secret_id))
      .includes(:source, :rules)
      .order(:id)
  end

  # gcp_auth credentials this proxy may receive, via its principal's grants.
  def granted_gcp_auth_secrets
    GcpAuthSecret
      .where(id: principal.grants.select(:gcp_auth_secret_id))
      .includes(:keyfile_source, :rules)
      .order(:id)
  end

  # oauth_token credentials this proxy may receive, via its principal's grants.
  def granted_oauth_token_secrets
    OauthTokenSecret
      .where(id: principal.grants.select(:oauth_token_secret_id))
      .includes(:sources, :rules)
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

  # Opaque, deterministic fingerprint of the delivered config. The proxy treats
  # this as an ETag: it echoes its current hash on each sync and only re-applies
  # config when the hash changes.
  def config_hash
    payload = { "secrets" => sync_secrets, "transforms" => sync_transforms }
    "sha256:#{Digest::SHA256.hexdigest(self.class.canonical_json(payload))}"
  end

  # Deep key-sorted JSON so the hash is stable regardless of Hash insertion or
  # jsonb column ordering.
  def self.canonical_json(value)
    JSON.generate(canonicalize(value))
  end

  def self.canonicalize(value)
    case value
    when Hash
      value.sort_by { |k, _| k.to_s }.to_h.transform_values { |v| canonicalize(v) }
    when Array
      value.map { |v| canonicalize(v) }
    else
      value
    end
  end

  private

  def issue_token
    return if bearer_token_hash.present?
    self.token = "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
    self.bearer_token_hash = self.class.hash_token(token)
  end

  def token_matches_format
    return if token.blank?
    return if token.match?(TOKEN_FORMAT)
    errors.add(:token, "must match #{TOKEN_FORMAT.inspect} (iprx_ + 32-byte lowercase hex)")
  end
end
