module Api
  module V1
    class PrincipalsController < Api::BaseController
      def show
        principal = Principal.find_by_oid!(params[:id])
        render json: serialize(principal)
      end

      def create
        principal = Principal.new(data_params.permit(:namespace, :foreign_id, labels: {}))
        principal.save!
        render status: :created, json: serialize(principal)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        principal = Principal.find_by_oid!(params[:id])
        principal.update!(data_params.permit(labels: {}))
        render json: serialize(principal)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      def serialize(principal)
        {
          data: {
            id: principal.oid,
            namespace: principal.namespace,
            foreign_id: principal.foreign_id,
            labels: principal.labels,
            created_at: principal.created_at,
            updated_at: principal.updated_at
          }
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
