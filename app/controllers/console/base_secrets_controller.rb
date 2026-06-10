module Console
  # Shared skeleton for the per-type secret form controllers: the new/create/edit/
  # update actions, view resolution, and the parts every secret has regardless of
  # kind (identity + labels, and building its SecretSource). A subclass declares
  # its #model and #kind and implements #assign_form for the type-specific config,
  # source association, and (where applicable) rules.
  class BaseSecretsController < ApplicationController
    include SecretKinds

    layout "console"

    before_action :assign_kind
    before_action :set_secret, only: %i[edit update]

    # The shared form templates/partials live under app/views/console/secrets, but
    # each subclass's controller path is console/<type>_secrets; add that prefix so
    # bare template/partial names resolve there.
    def _prefixes
      @_prefixes ||= super + %w[console/secrets]
    end

    def new
      @secret = model.new(namespace: "default")
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

    def edit; end

    def update
      assign(@secret)
      if @secret.save
        redirect_to console_secret_path(kind, @secret.oid), notice: "Secret updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def model
      raise NotImplementedError, "#{self.class} must define #model"
    end

    def kind
      raise NotImplementedError, "#{self.class} must define #kind"
    end

    def assign_form(_secret)
      raise NotImplementedError, "#{self.class} must define #assign_form"
    end

    def assign(secret)
      assign_identity(secret)
      assign_form(secret)
    end

    # namespace / foreign_id / name / description / labels — common to every kind.
    # A blank namespace defaults to "default"; a blank foreign_id becomes nil so
    # the allow_nil validations apply (an empty string would fail the URL-safe
    # format).
    def assign_identity(secret)
      attrs = params.fetch(:secret, ActionController::Parameters.new)
              .permit(:namespace, :foreign_id, :name, :description)
      attrs[:namespace] = attrs[:namespace].presence || "default"
      attrs[:foreign_id] = attrs[:foreign_id].presence
      secret.assign_attributes(attrs)
      secret.labels = label_params
    end

    def label_params
      rows = params[:labels]
      return {} if rows.blank?
      rows.to_unsafe_h.values.each_with_object({}) do |row, acc|
        key = row["key"].to_s.strip
        acc[key] = row["value"].to_s if key.present?
      end
    end

    # Build the SecretSource described by the `source` params, or nil when no
    # backend was chosen. The subclass assigns it to the right has_one association
    # (source / dsn_source).
    def build_source
      sp = params.fetch(:source, ActionController::Parameters.new)
      type = sp[:source_type].presence
      return nil if type.nil?

      config = {}
      attrs = { source_type: type }
      if type == "control_plane"
        attrs[:secret] = sp[:secret]
      elsif (ref_key = SOURCE_REF_KEYS[type])
        config[ref_key] = sp[:reference].strip if sp[:reference].present?
      end
      config["region"] = sp[:region].strip if sp[:region].present? && %w[aws_sm aws_ssm].include?(type)
      config["json_key"] = sp[:json_key].strip if sp[:json_key].present?
      attrs[:config] = config

      SecretSource.new(attrs)
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
