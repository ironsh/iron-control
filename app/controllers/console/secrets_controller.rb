module Console
  # Create/edit forms for secrets in the operator console. Unlike the JSON API,
  # this builds the ActiveRecord graph directly and relies on the same model
  # validations, re-rendering the form with inline errors when a save fails. Only
  # kinds flagged `form: true` in SecretKinds are reachable; the rest 404 until
  # their form is implemented.
  class SecretsController < ApplicationController
    include SecretKinds
    include SecretFormParams

    layout "console"

    before_action :set_kind
    before_action :set_secret, only: %i[edit update]

    def new
      @secret = @model.new(namespace: "default")
    end

    def create
      @secret = @model.new(created_by: current_user)
      assign_attributes(@secret)
      if @secret.save
        redirect_to console_secret_path(@kind, @secret.oid), notice: "Secret created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      assign_attributes(@secret)
      if @secret.save
        redirect_to console_secret_path(@kind, @secret.oid), notice: "Secret updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_kind
      cfg = SECRET_KINDS[params[:kind]]
      return render plain: "secret not found", status: :not_found unless cfg && cfg[:form]
      @kind = params[:kind]
      @model = cfg[:model]
    end

    def set_secret
      @secret = @model.find_by_oid!(params[:id])
    rescue ActiveRecord::RecordNotFound
      render plain: "secret not found", status: :not_found
    end

    # Fold the posted params onto the secret graph, dispatching the type-specific
    # config/source/rules to the matching SecretFormParams builder.
    def assign_attributes(secret)
      assign_common_attributes(secret)
      case @kind
      when "static" then assign_static(secret)
      when "pg_dsn" then assign_pg_dsn(secret)
      end
    end
  end
end
