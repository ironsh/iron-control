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
        attrs = data_params.permit(:namespace, :foreign_id, :name, labels: {})
        attrs[:namespace] = "default" if attrs[:namespace].blank?
        principal = Principal.new(attrs)
        principal.save!
        render status: :created, json: { data: record_payload(principal) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        principal = Principal.find_by_oid!(params[:id])
        principal.update!(data_params.permit(:name, labels: {}))
        render json: { data: record_payload(principal) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
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
