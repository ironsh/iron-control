module Console
  # Create/edit form for PgDsnSecret: a required database routing key, optional
  # upstream role, optional pinned session settings, and a single DSN source
  # (no rules).
  class PgDsnSecretsController < BaseSecretsController
    private

    def model
      PgDsnSecret
    end

    def kind
      "pg_dsn"
    end

    def assign_form(secret)
      assign_identity(secret)
      pg = params.fetch(:secret, ActionController::Parameters.new)
      secret.database = pg[:database].presence
      secret.role = pg[:role].presence
      secret.settings = setting_rows(params[:settings])
      secret.dsn_source = build_source
    end

    # The pinned session settings as an ordered array of { "name", "value" }
    # hashes (order matters: the proxy applies them in sequence). Rows with a
    # blank name are dropped; the model validates names and uniqueness.
    def setting_rows(raw)
      (raw&.to_unsafe_h || {}).values.filter_map do |row|
        name = row["name"].to_s.strip
        next if name.blank?
        { "name" => name, "value" => row["value"].to_s }
      end
    end
  end
end
