module Api
  module V1
    # Operator CRUD for OAuth apps. Mirrors Api::V1::BrokerCredentialsController
    # (oid/foreign_id addressing, label search, PUT-upsert), with one difference:
    # client_secret is a write-only field and is NEVER serialized back -- only a
    # `client_secret_set` boolean is.
    class OauthAppsController < Api::BaseController
      def index
        records, meta = paginated_label_search(OauthApp.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        render json: { data: record_payload(OauthApp.find_by_oid!(params[:id])) }
      end

      # GET /api/v1/oauth_apps/lookup/:namespace/:foreign_id
      def lookup
        render json: { data: record_payload(find_by_foreign_id!(OauthApp)) }
      end

      def create
        app = OauthApp.new(created_by: current_user)
        assign_and_save!(app, data_params)
        render status: :created, json: { data: record_payload(app) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        app = resolve_for_upsert(OauthApp)
        was_new = app.new_record?
        assign_and_save!(app, data_params)
        render status: (was_new ? :created : :ok), json: { data: record_payload(app) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        app = OauthApp.find_by_oid!(params[:id])
        app.destroy!
        head :no_content
      rescue ActiveRecord::RecordNotDestroyed
        render status: :conflict, json: { error: { message: app.errors.full_messages.to_sentence } }
      end

      private

      def assign_and_save!(app, attrs)
        base = attrs.permit(:namespace, :foreign_id, :name, :description, :provider,
                            :client_id, :client_secret, :credential_namespace, :enabled,
                            labels: {}, allowed_scopes: [], allowed_return_urls: [])
        # A PUT upsert by foreign_id sets identity before assignment; a blank body
        # value must not wipe it.
        base.delete(:foreign_id) if base[:foreign_id].blank? && app.foreign_id.present?
        base.delete(:namespace) if base[:namespace].blank? && app.namespace.present?
        base[:namespace] = "default" if base[:namespace].blank? && app.namespace.blank?
        # client_secret is write-only: only assign when supplied, so a partial
        # update leaves the stored secret in place.
        base.delete(:client_secret) if base[:client_secret].blank?

        app.assign_attributes(base)
        app.save!
      end

      # Observability only. The client_secret is deliberately never included; only
      # whether one is set.
      def record_payload(app)
        {
          id: app.oid,
          namespace: app.namespace,
          foreign_id: app.foreign_id,
          name: app.name,
          description: app.description,
          labels: app.labels,
          provider: app.provider,
          client_id: app.client_id,
          client_secret_set: app.client_secret.present?,
          allowed_scopes: app.allowed_scopes,
          allowed_return_urls: app.allowed_return_urls,
          credential_namespace: app.credential_namespace,
          enabled: app.enabled,
          created_at: app.created_at,
          updated_at: app.updated_at
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
