class SecretSource < ApplicationRecord
  oid_prefix "scs"

  SOURCE_TYPES = %w[env aws_sm aws_ssm 1password 1password_connect control_plane token_broker].freeze

  UNIVERSAL_OPTIONAL = %w[json_key ttl].freeze

  CONFIG_SCHEMA = {
    "env" => { required: %w[var], optional: [] },
    "aws_sm" => { required: %w[secret_id], optional: %w[region] },
    "aws_ssm" => { required: %w[name], optional: %w[region with_decryption] },
    "1password" => { required: %w[secret_ref], optional: %w[token_env] },
    "1password_connect" => { required: %w[secret_ref], optional: %w[host_env token_env] },
    "control_plane" => { required: [], optional: [] },
    "token_broker" => { required: %w[credential_id], optional: %w[failure_ttl] }
  }.freeze

  # A source belongs to exactly one owner. static_secret feeds the `secrets`
  # transform; gcp_auth_secret is a gcp_auth keyfile; oauth_token_secret holds
  # one oauth_token entry's credential fields and token-endpoint headers.
  belongs_to :static_secret, optional: true
  belongs_to :gcp_auth_secret, optional: true
  belongs_to :oauth_token_secret, optional: true

  # Only set for oauth_token_secret-owned sources: whether `role` names a
  # credential field (client_id, ...) or a token-endpoint header.
  enum :role_kind, { credential_field: "credential_field", endpoint_header: "endpoint_header" }, validate: { allow_nil: true }

  encrypts :secret

  attr_readonly :source_type

  # Maps this source to the iron-proxy `secrets` transform `source` block,
  # discriminated by `type`. For control_plane sources the decrypted value is
  # delivered inline; all other types pass their config through (the proxy's
  # backend resolvers read the matching keys and ignore unknown ones).
  def to_proxy_source
    source = config.is_a?(Hash) ? config.dup : {}
    source["type"] = source_type
    source["value"] = secret if source_type == "control_plane"
    source
  end

  OWNER_ASSOCIATIONS = %i[static_secret gcp_auth_secret oauth_token_secret].freeze

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validate :config_is_a_hash
  validate :config_matches_source_type
  validate :secret_matches_source_type
  validate :at_most_one_owner
  validate :role_matches_owner

  private

  def at_most_one_owner
    # Check the association object, not just the FK column: when built through a
    # parent (parent.sources.build / parent.keyfile_source =) autosave validates
    # this record before the parent is persisted, so the FK is still nil but the
    # inverse association is already set.
    set = OWNER_ASSOCIATIONS.count { |assoc| send(assoc).present? }
    return if set <= 1
    errors.add(:base, "must belong to at most one of #{OWNER_ASSOCIATIONS.join(", ")}")
  end

  def role_matches_owner
    if oauth_token_secret.present?
      errors.add(:role, "can't be blank for an oauth_token_secret source") if role.blank?
      errors.add(:role_kind, "can't be blank for an oauth_token_secret source") if role_kind.blank?
    else
      errors.add(:role, "is only allowed for an oauth_token_secret source") if role.present?
      errors.add(:role_kind, "is only allowed for an oauth_token_secret source") if role_kind.present?
    end
  end

  def config_is_a_hash
    errors.add(:config, "must be a hash") unless config.is_a?(Hash)
  end

  def config_matches_source_type
    return unless config.is_a?(Hash)
    schema = CONFIG_SCHEMA[source_type]
    return unless schema

    keys = config.keys.map(&:to_s)
    allowed = schema[:required] + schema[:optional] + UNIVERSAL_OPTIONAL

    (schema[:required] - keys).each do |missing|
      errors.add(:config, "is missing required key #{missing.inspect} for source_type #{source_type.inspect}")
    end

    (keys - allowed).each do |unknown|
      errors.add(:config, "has unknown key #{unknown.inspect} for source_type #{source_type.inspect}")
    end
  end

  def secret_matches_source_type
    if source_type == "control_plane"
      errors.add(:secret, "can't be blank for source_type \"control_plane\"") if secret.blank?
    elsif secret.present?
      errors.add(:secret, "is only allowed for source_type \"control_plane\"")
    end
  end
end
