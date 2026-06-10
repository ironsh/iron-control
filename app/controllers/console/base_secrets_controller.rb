module Console
  # Shared new/create/edit/update flow for the per-type secret form controllers.
  # A subclass declares its #model and #kind and implements #assign_form to fold
  # the type-specific params onto the secret; this base owns identity/labels, the
  # save, and rendering of the shared form templates. Forms build the model graph
  # directly and lean on the model's own validations, re-rendering with inline
  # errors when a save fails.
  class BaseSecretsController < ApplicationController
    include SecretKinds
    include SecretFormParams

    layout "console"

    before_action :assign_kind
    before_action :set_secret, only: %i[edit update]

    # The shared form templates and partials live under app/views/console/secrets,
    # but each subclass's controller path is console/<type>_secrets. Add that
    # shared prefix to the view lookup so bare template/partial names resolve there.
    def _prefixes
      @_prefixes ||= super + %w[console/secrets]
    end

    def new
      @secret = model.new(namespace: "default")
      render :new
    end

    def create
      @secret = model.new(created_by: current_user)
      assign(@secret)
      if @secret.save
        redirect_to console_secret_path(kind, @secret.oid), notice: "Secret created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      render :edit
    end

    def update
      assign(@secret)
      if @secret.save
        redirect_to console_secret_path(kind, @secret.oid), notice: "Secret updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # --- subclass responsibilities ---------------------------------------

    def model
      raise NotImplementedError, "#{self.class} must define #model"
    end

    def kind
      raise NotImplementedError, "#{self.class} must define #kind"
    end

    # Fold the type-specific config/source/rules onto the secret. Identity and
    # labels are already applied by the time this runs.
    def assign_form(_secret)
      raise NotImplementedError, "#{self.class} must define #assign_form"
    end

    # --- shared flow ------------------------------------------------------

    def assign(secret)
      assign_common_attributes(secret)
      assign_form(secret)
    end

    def assign_kind
      @kind = kind
    end

    def set_secret
      @secret = model.find_by_oid!(params[:id])
    rescue ActiveRecord::RecordNotFound
      render plain: "secret not found", status: :not_found
    end
  end
end
