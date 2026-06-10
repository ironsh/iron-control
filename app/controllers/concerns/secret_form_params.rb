# Shared helpers for turning the console secret forms' params into a secret's
# common attributes and its associated SecretSource / RequestRule records. The
# per-type controllers compose these with their own config building; nothing here
# is type-specific.
#
# Nothing here saves: the controller owns the save so it can re-render with the
# model's own validation errors on failure.
module SecretFormParams
  extend ActiveSupport::Concern

  private

  # namespace / foreign_id / name / description / labels, common to every kind.
  # A blank namespace defaults to "default"; a blank foreign_id becomes nil so the
  # allow_nil format/uniqueness validations apply (an empty string would fail the
  # URL-safe format).
  def assign_common_attributes(secret)
    sp = params.fetch(:secret, ActionController::Parameters.new)
         .permit(:namespace, :foreign_id, :name, :description)
    sp[:namespace] = sp[:namespace].presence || "default"
    sp[:foreign_id] = sp[:foreign_id].presence
    secret.assign_attributes(sp)
    secret.labels = parse_labels
  end

  # Build the request rules from the indexed `rules` param onto the secret,
  # replacing any existing collection. Fully-blank rows are dropped; position is
  # assigned from the surviving order. http_methods and paths arrive as delimited
  # text and are parsed to arrays (the model validates their contents).
  def assign_rules(secret)
    rows = indexed_rows(params.fetch(:rules, nil)).reject do |r|
      r[:host].blank? && r[:cidr].blank? && r[:http_methods].blank? && r[:paths].blank?
    end
    secret.rules = rows.each_with_index.map do |r, i|
      RequestRule.new(
        host: r[:host].presence,
        cidr: r[:cidr].presence,
        http_methods: split_methods(r[:http_methods]),
        paths: split_paths(r[:paths]),
        position: i
      )
    end
  end

  # Build a single SecretSource for the given has_one association (:source or
  # :dsn_source), replacing any existing one. A blank source_type leaves the
  # association unset so the model's own presence rules (if any) report it.
  def assign_source(secret, assoc)
    sp = params.fetch(:source, ActionController::Parameters.new)
    type = sp[:source_type].presence
    return secret.public_send("#{assoc}=", nil) if type.nil?

    attrs = { source_type: type }
    config = {}
    if type == "control_plane"
      attrs[:secret] = sp[:secret]
    elsif (ref_key = SecretKinds::SOURCE_REF_KEYS[type])
      config[ref_key] = sp[:reference].strip if sp[:reference].present?
    end
    config["region"] = sp[:region].strip if sp[:region].present? && %w[aws_sm aws_ssm].include?(type)
    config["json_key"] = sp[:json_key].strip if sp[:json_key].present?
    attrs[:config] = config

    secret.public_send("#{assoc}=", SecretSource.new(attrs))
  end

  def parse_labels
    indexed_rows(params.fetch(:labels, nil)).each_with_object({}) do |row, acc|
      key = row[:key].to_s.strip
      acc[key] = row[:value].to_s unless key.blank?
    end
  end

  # The indexed nested param (`rules[0][host]`, `labels[1][key]`, ...) as an array
  # of plain hashes, ordered by the numeric index the form assigned.
  def indexed_rows(group)
    return [] if group.blank?
    group.to_unsafe_h.sort_by { |k, _| k.to_i }.map { |_, v| v.is_a?(Hash) ? v.symbolize_keys : {} }
  end

  def split_methods(value)
    value.to_s.split(/[,\s]+/).map { |m| m.strip.upcase }.reject(&:blank?)
  end

  def split_paths(value)
    value.to_s.split(/[\r\n,]+/).map(&:strip).reject(&:blank?)
  end

  def split_list(value)
    value.to_s.split(",").map(&:strip).reject(&:blank?)
  end

  def boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
