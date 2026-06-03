module Api
  module V1
    class PgDsnSecretsController < Api::BaseController
      def index
        records, meta = paginated_label_search(PgDsnSecret.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        ref = PgDsnSecret.find_by_oid!(params[:id])
        render json: { data: record_payload(ref) }
      end

      # GET /api/v1/pg_dsn_secrets/lookup/:namespace/:foreign_id
      def lookup
        render json: { data: record_payload(find_by_foreign_id!(PgDsnSecret)) }
      end

      def create
        ref = PgDsnSecret.new(created_by: current_user)
        assign_and_save!(ref, data_params)
        render status: :created, json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      # PUT/PATCH upserts: an opaque id updates that record, any other identifier
      # is a foreign_id that is created when absent.
      def update
        ref = resolve_for_upsert(PgDsnSecret)
        was_new = ref.new_record?
        assign_and_save!(ref, data_params)
        render status: (was_new ? :created : :ok), json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      def assign_and_save!(ref, attrs)
        base = attrs.permit(
          :namespace, :foreign_id, :name, :description, :database, :role, labels: {}
        )
        # A PUT upsert by foreign_id sets identity on the record before
        # assignment; a blank body value must not wipe it.
        base.delete(:foreign_id) if base[:foreign_id].blank? && ref.foreign_id.present?
        base.delete(:namespace) if base[:namespace].blank? && ref.namespace.present?
        base[:namespace] = "default" if base[:namespace].blank? && ref.namespace.blank?

        source_attrs = if attrs.key?(:dsn) && attrs[:dsn].present?
          attrs.require(:dsn).permit(:source_type, :secret, config: {})
        end

        # Build the whole graph in memory and save once so the cross-record
        # validation (dsn_source_present) sees the source. Assigning the has_one
        # replaces (and destroys) any prior source; a PUT is a full replace.
        PgDsnSecret.transaction do
          ref.assign_attributes(base)
          ref.dsn_source = source_attrs ? SecretSource.new(source_attrs.to_h) : nil
          ref.save!
          ref.reload
        end
      end

      def record_payload(ref)
        {
          id: ref.oid,
          namespace: ref.namespace,
          foreign_id: ref.foreign_id,
          name: ref.name,
          description: ref.description,
          labels: ref.labels,
          database: ref.database,
          role: ref.role,
          dsn: ref.dsn_source && {
            source_type: ref.dsn_source.source_type,
            config: ref.dsn_source.config
          },
          created_at: ref.created_at,
          updated_at: ref.updated_at
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
