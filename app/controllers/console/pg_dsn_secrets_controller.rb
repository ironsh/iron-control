module Console
  # Create/edit form for PgDsnSecret: a required database routing key, optional
  # upstream role, and a single DSN source (no rules).
  class PgDsnSecretsController < BaseSecretsController
    private

    def model
      PgDsnSecret
    end

    def kind
      "pg_dsn"
    end

    def assign_form(secret)
      pg = params.fetch(:secret, ActionController::Parameters.new).permit(:database, :role)
      secret.database = pg[:database].presence
      secret.role = pg[:role].presence
      secret.dsn_source = build_source
    end
  end
end
