class SecretSource < ApplicationRecord
  oid_prefix "scs"

  SOURCE_TYPES = %w[env aws_sm aws_ssm 1password 1password_connect].freeze

  UNIVERSAL_OPTIONAL = %w[json_key ttl].freeze

  CONFIG_SCHEMA = {
    "env" => { required: %w[var], optional: [] },
    "aws_sm" => { required: %w[secret_id], optional: %w[region] },
    "aws_ssm" => { required: %w[name], optional: %w[region with_decryption] },
    "1password" => { required: %w[secret_ref], optional: %w[token_env] },
    "1password_connect" => { required: %w[secret_ref], optional: %w[host_env token_env] }
  }.freeze

  belongs_to :static_secret_ref, optional: true

  attr_readonly :source_type

  validates :source_type, presence: true, inclusion: { in: SOURCE_TYPES }
  validate :config_is_a_hash
  validate :config_matches_source_type

  private

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
end
