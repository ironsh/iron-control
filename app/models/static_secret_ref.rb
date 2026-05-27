class StaticSecretRef < ApplicationRecord
  oid_prefix "ssc"

  NAME_FORMAT = /\A[a-zA-Z0-9_-]+\z/
  METADATA_MAX_BYTES = 4096

  INJECT_CONFIG_SCHEMA = JSONSchemer.schema({
    "type" => "object",
    "additionalProperties" => false,
    "properties" => {
      "header" => { "type" => "string", "minLength" => 1 },
      "formatter" => { "type" => "string" },
      "query_param" => { "type" => "string", "minLength" => 1 }
    },
    "oneOf" => [
      { "required" => [ "header" ] },
      { "required" => [ "query_param" ] }
    ]
  })

  REPLACE_CONFIG_SCHEMA = JSONSchemer.schema({
    "type" => "object",
    "additionalProperties" => false,
    "required" => [ "proxy_value" ],
    "properties" => {
      "proxy_value" => { "type" => "string", "minLength" => 1 },
      "match_headers" => { "type" => "array", "items" => { "type" => "string" } },
      "match_body" => { "type" => "boolean" },
      "match_path" => { "type" => "boolean" },
      "match_query" => { "type" => "boolean" },
      "require" => { "type" => "boolean" }
    }
  })

  has_one :source, class_name: "SecretSource", dependent: :nullify
  has_many :rules, class_name: "RequestRule", dependent: :nullify

  validates :namespace, presence: true
  validates :name,
            presence: true,
            uniqueness: { scope: :namespace },
            format: { with: NAME_FORMAT, message: "may only contain letters, numbers, underscores, and hyphens" }
  validate :labels_is_a_hash
  validate :metadata_is_a_hash
  validate :metadata_within_size_limit
  validate :exactly_one_of_inject_or_replace
  validate :inject_config_matches_schema
  validate :replace_config_matches_schema

  private

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  def metadata_is_a_hash
    errors.add(:metadata, "must be a hash") unless metadata.is_a?(Hash)
  end

  def metadata_within_size_limit
    return unless metadata.is_a?(Hash)
    if metadata.to_json.bytesize > METADATA_MAX_BYTES
      errors.add(:metadata, "must be at most #{METADATA_MAX_BYTES} bytes when serialized as JSON")
    end
  end

  def exactly_one_of_inject_or_replace
    present = [ inject_config.present?, replace_config.present? ].count(true)
    if present.zero?
      errors.add(:base, "must define one of inject_config or replace_config")
    elsif present > 1
      errors.add(:base, "inject_config and replace_config are mutually exclusive")
    end
  end

  def inject_config_matches_schema
    validate_against_schema(:inject_config, inject_config, INJECT_CONFIG_SCHEMA)
  end

  def replace_config_matches_schema
    validate_against_schema(:replace_config, replace_config, REPLACE_CONFIG_SCHEMA)
  end

  def validate_against_schema(attr, value, schema)
    return if value.blank?
    unless value.is_a?(Hash)
      errors.add(attr, "must be a hash")
      return
    end
    schema.validate(value).each do |err|
      pointer = err["data_pointer"].presence || "(root)"
      errors.add(attr, "#{pointer} #{err["error"]}")
    end
  end
end
