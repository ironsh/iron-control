# View helpers for rendering per-field validation errors on the console secret
# forms. These render behavior (error lookup + markup), not static class strings;
# the field styling lives in Tailwind component classes.
module ConsoleFormHelper
  # A small red message listing the record's errors for one attribute, or nil
  # when there are none (or the record is absent, as on a fresh form).
  def field_error(record, attr)
    return if record.nil?
    messages = record.errors[attr]
    return if messages.blank?
    tag.p(messages.to_sentence, class: "field-error")
  end

  # The error modifier class to append to a field's class list when its attribute
  # is invalid, or "" otherwise.
  def field_error_class(record, attr)
    return "" if record.nil?
    record.errors[attr].present? ? "form-input-error" : ""
  end

  # Flat list of human messages for the form's error summary. Nested source/rule
  # records are saved via autosave, which adds only a generic "is invalid" on the
  # parent for the association; we drop those and surface the children's own
  # detailed messages, prefixed by which record they came from.
  def secret_error_messages(secret)
    nested_attrs = %i[source dsn_source keyfile_source rules]
    messages = secret.errors.reject { |e| nested_attrs.include?(e.attribute) }.map(&:full_message)

    %i[source dsn_source keyfile_source].each do |assoc|
      next unless secret.respond_to?(assoc)
      child = secret.public_send(assoc)
      next unless child&.errors&.any?
      child.errors.full_messages.each { |m| messages << "Source: #{m}" }
    end

    if secret.respond_to?(:rules)
      secret.rules.each_with_index do |rule, i|
        rule.errors.full_messages.each { |m| messages << "Rule #{i + 1}: #{m}" }
      end
    end

    messages
  end
end
