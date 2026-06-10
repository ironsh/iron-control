# Translates the console secret forms' params into the secret object graph. The
# forms post flat, type-agnostic param groups (`secret`, `source`, `rules`,
# `labels`, plus the static-only `static`); this concern folds them onto a secret
# model and its associated SecretSource / RequestRule records, which a single
# `secret.save` then validates and persists atomically (autosave cascades).
#
# Nothing here saves: the controller owns the save so it can re-render with the
# model's own validation errors on failure. The rule and source helpers are the
# reusable pieces shared by every rule/source-bearing secret kind.
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

  # StaticSecret: an inject/replace config (exactly one, enforced by the model),
  # one optional source, and any number of request rules.
  def assign_static(secret)
    st = params.fetch(:static, ActionController::Parameters.new)
    if st[:mode] == "replace"
      secret.inject_config = nil
      secret.replace_config = build_replace_config(st)
    else
      secret.replace_config = nil
      secret.inject_config = build_inject_config(st)
    end
    assign_source(secret, :source)
    assign_rules(secret)
  end

  # PgDsnSecret: a required database routing key, optional upstream role, and a
  # single DSN source (no rules).
  def assign_pg_dsn(secret)
    pg = params.fetch(:secret, ActionController::Parameters.new).permit(:database, :role)
    secret.database = pg[:database].presence
    secret.role = pg[:role].presence
    assign_source(secret, :dsn_source)
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

  def build_inject_config(st)
    cfg = {}
    cfg["header"] = st[:header].strip if st[:header].present?
    cfg["query_param"] = st[:query_param].strip if st[:query_param].present?
    cfg["formatter"] = st[:formatter] if st[:formatter].present?
    cfg.presence
  end

  def build_replace_config(st)
    cfg = { "proxy_value" => st[:proxy_value].to_s }
    headers = split_list(st[:match_headers])
    cfg["match_headers"] = headers if headers.any?
    cfg["match_body"] = true if boolean(st[:match_body])
    cfg["match_path"] = true if boolean(st[:match_path])
    cfg["match_query"] = true if boolean(st[:match_query])
    cfg["require"] = true if boolean(st[:require])
    cfg
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
