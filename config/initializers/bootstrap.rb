Rails.application.config.after_initialize do
  next if Rails.env.test?
  next if ENV["IRON_CONTROL_INITIAL_USER_EMAIL"].to_s.strip.empty?

  begin
    Iron::Bootstrap.run!
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
    # DB not provisioned yet (e.g. running `db:create`); skip silently.
  end
end
