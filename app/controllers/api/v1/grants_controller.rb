module Api
  module V1
    class GrantsController < Api::BaseController
      def show
        grant = Grant.find_by_oid!(params[:id])
        render json: serialize(grant)
      end

      def create
        attrs = data_params.permit(:principal_id, :static_secret_ref_id)
        principal = Principal.find_by_oid!(attrs[:principal_id])
        static_secret_ref = StaticSecretRef.find_by_oid!(attrs[:static_secret_ref_id])

        grant = Grant.create!(
          principal: principal,
          static_secret_ref: static_secret_ref,
          created_by: current_api_key
        )
        render status: :created, json: serialize(grant)
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        grant = Grant.find_by_oid!(params[:id])
        grant.destroy!
        head :no_content
      end

      private

      def serialize(grant)
        {
          data: {
            id: grant.oid,
            principal_id: grant.principal.oid,
            static_secret_ref_id: grant.static_secret_ref.oid,
            created_at: grant.created_at,
            updated_at: grant.updated_at
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
