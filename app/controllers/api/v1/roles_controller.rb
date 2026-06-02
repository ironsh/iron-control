module Api
  module V1
    class RolesController < Api::BaseController
      def index
        records, meta = paginated_label_search(Role.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        role = Role.find_by_oid!(params[:id])
        render json: { data: record_payload(role) }
      end

      def lookup
        namespace = params.require(:namespace)
        foreign_id = params.require(:foreign_id)
        role = Role.find_by!(namespace: namespace, foreign_id: foreign_id)
        render json: { data: record_payload(role) }
      end

      def create
        role = Role.new(namespace: upsert_namespace, foreign_id: data_params[:foreign_id],
                        created_by: current_user)
        role.assign_attributes(data_params.permit(:name, labels: {}))
        role.save!
        render status: :created, json: { data: record_payload(role) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      # PUT/PATCH upserts: an opaque id updates that record, any other identifier
      # is a foreign_id that is created when absent. namespace and foreign_id are
      # immutable, so they only take effect when the record is created.
      def update
        role = resolve_for_upsert(Role)
        was_new = role.new_record?
        role.assign_attributes(data_params.permit(:name, labels: {}))
        role.save!
        render status: (was_new ? :created : :ok), json: { data: record_payload(role) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        role = Role.find_by_oid!(params[:id])
        role.destroy!
        head :no_content
      end

      private

      def record_payload(role)
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
