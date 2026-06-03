module Api
  module V1
    class PrincipalsController < Api::BaseController
      def index
        records, meta = paginated_label_search(Principal.all)
        render json: { data: records.map { |p| record_payload(p) }, meta: meta }
      end

      def show
        principal = Principal.find_by_oid!(params[:id])
        render json: { data: record_payload(principal) }
      end

      def lookup
        namespace = params.require(:namespace)
        foreign_id = params.require(:foreign_id)
        principal = Principal.find_by!(namespace: namespace, foreign_id: foreign_id)
        render json: { data: record_payload(principal) }
      end

      def create
        principal = Principal.new(namespace: upsert_namespace, foreign_id: data_params[:foreign_id],
                                  created_by: current_user)
        principal.assign_attributes(data_params.permit(:name, labels: {}))
        principal.save!
        render status: :created, json: { data: record_payload(principal) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      # PUT/PATCH upserts: an opaque id updates that record, any other identifier
      # is a foreign_id that is created when absent. namespace and foreign_id are
      # immutable, so they only take effect when the record is created.
      def update
        principal = resolve_for_upsert(Principal)
        was_new = principal.new_record?
        principal.assign_attributes(data_params.permit(:name, labels: {}))
        principal.save!
        render status: (was_new ? :created : :ok), json: { data: record_payload(principal) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      # GET /api/v1/principals/:id/effective_config
      #
      # :id accepts either an opaque oid or a foreign_id (scoped to the
      # `namespace` query param, defaulting to "default").
      #
      # The config this principal resolves to, in the same shape iron-proxy
      # receives on /sync, for operator inspection. Unlike /sync it never reveals
      # live secrets (inline control_plane values are redacted) and does no
      # config-hash negotiation. We send a content-derived ETag for change
      # detection but mark the response no-store, since it reflects mutable
      # grants and must never be served from a cache.
      def effective_config
        principal = resolve_for_read(Principal)
        body = { data: { id: principal.oid }.merge(principal.effective_config) }.to_json

        response.headers["ETag"] = %("#{Digest::SHA256.hexdigest(body)}")
        response.headers["Cache-Control"] = "no-store"
        render json: body
      end

      private

      def record_payload(principal)
        {
          id: principal.oid,
          namespace: principal.namespace,
          foreign_id: principal.foreign_id,
          name: principal.name,
          labels: principal.labels,
          created_at: principal.created_at,
          updated_at: principal.updated_at
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
