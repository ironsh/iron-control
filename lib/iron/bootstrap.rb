module Iron
  module Bootstrap
    ADVISORY_LOCK_KEY = 0x1700_B007_C0FFEE & 0x7FFF_FFFF_FFFF_FFFF

    API_KEY_FORMAT = /\Aiak_[0-9a-f]{64}\z/

    Error = Class.new(StandardError)

    module_function

    def run!(logger: Rails.logger)
      email = ENV["IRON_BOOT_INITIAL_USER_EMAIL"].to_s.strip
      return if email.empty?

      password = ENV["IRON_BOOT_INITIAL_USER_PASSWORD"].to_s
      if password.empty?
        raise Error, "IRON_BOOT_INITIAL_USER_EMAIL is set but IRON_BOOT_INITIAL_USER_PASSWORD is missing"
      end

      supplied_token = ENV["IRON_BOOT_INITIAL_API_KEY"].to_s
      if !supplied_token.empty? && supplied_token !~ API_KEY_FORMAT
        raise Error, "IRON_BOOT_INITIAL_API_KEY must match #{API_KEY_FORMAT.inspect} (iak_ + 32-byte lowercase hex)"
      end

      return unless ActiveRecord::Base.connection.data_source_exists?("users")
      return if User.exists?

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")
        return if User.exists?

        user = User.create!(email: email, password: password)

        api_key = ApiKey.new(user: user, name: "bootstrap")
        if supplied_token.empty?
          api_key.save!
        else
          api_key.token = supplied_token
          api_key.token_hash = ApiKey.hash_token(supplied_token)
          api_key.save!
        end

        log_line = "iron-control bootstrap: created user id=#{user.id} email=#{user.email} api_key_id=#{api_key.id}"
        log_line += " api_key=#{api_key.token}" if supplied_token.empty?
        logger.info(log_line)
      end
    end
  end
end
