module Api
  module V1
    class GrantsController < Api::BaseController
      def show
        grant = Grant.find_by_oid!(params[:id])
        render json: serialize(grant)
      end

      GRANTABLE_TYPES = {
        static_secret_id: StaticSecret,
        gcp_auth_secret_id: GcpAuthSecret,
        oauth_token_secret_id: OauthTokenSecret
      }.freeze

      def create
        attrs = data_params.permit(:principal_id, *GRANTABLE_TYPES.keys)
        principal = Principal.find_by_oid!(attrs[:principal_id])

        grantable_key = GRANTABLE_TYPES.keys.find { |k| attrs[k].present? }
        unless grantable_key
          return render status: :unprocessable_entity, json: {
            error: { message: "validation failed",
                     details: { base: [ "must reference one of #{GRANTABLE_TYPES.keys.join(", ")}" ] } }
          }
        end
        grantable = GRANTABLE_TYPES.fetch(grantable_key).find_by_oid!(attrs[grantable_key])
        association = grantable_key.to_s.delete_suffix("_id").to_sym

        grant = Grant.create!(
          principal: principal,
          association => grantable,
          created_by: current_user
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
        grantable = grant.grantable
        key = GRANTABLE_TYPES.key(grantable.class)
        {
          data: {
            id: grant.oid,
            principal_id: grant.principal.oid,
            key => grantable.oid,
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
