module Api
  module V1
    # Manages role assignments for a principal:
    #   GET    /api/v1/principals/:principal_id/roles
    #   POST   /api/v1/principals/:principal_id/roles      (body: data: { role_id })
    #   DELETE /api/v1/principals/:principal_id/roles/:id  (:id is the role oid)
    class PrincipalRolesController < Api::BaseController
      def index
        principal = Principal.find_by_oid!(params[:principal_id])
        render json: { data: principal.roles.order(:id).map { |r| role_payload(r) } }
      end

      def create
        principal = Principal.find_by_oid!(params[:principal_id])
        role = Role.find_by_oid!(data_params.require(:role_id))
        principal.principal_roles.create!(role: role)
        render status: :created, json: { data: role_payload(role) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        principal = Principal.find_by_oid!(params[:principal_id])
        role = Role.find_by_oid!(params[:id])
        assignment = principal.principal_roles.find_by!(role: role)
        assignment.destroy!
        head :no_content
      end

      private

      def role_payload(role)
        {
          id: role.oid,
          namespace: role.namespace,
          foreign_id: role.foreign_id,
          name: role.name,
          labels: role.labels,
          created_at: role.created_at,
          updated_at: role.updated_at
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
