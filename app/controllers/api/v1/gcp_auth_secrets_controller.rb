module Api
  module V1
    class GcpAuthSecretsController < Api::BaseController
      def index
        records, meta = paginated_label_search(GcpAuthSecret.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        ref = GcpAuthSecret.find_by_oid!(params[:id])
        render json: { data: record_payload(ref) }
      end

      def create
        ref = GcpAuthSecret.new(created_by: current_user)
        assign_and_save!(ref, data_params)
        render status: :created, json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      # PUT/PATCH upserts: an opaque id updates that record, any other identifier
      # is a foreign_id that is created when absent.
      def update
        ref = resolve_for_upsert(GcpAuthSecret)
        was_new = ref.new_record?
        assign_and_save!(ref, data_params)
        render status: (was_new ? :created : :ok), json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      # Builds the whole credential graph in memory and saves once so the
      # cross-record validations (exactly_one_credential) see the keyfile source.
      def assign_and_save!(ref, attrs)
        base = attrs.permit(:namespace, :foreign_id, :name, :description, :subject,
                            labels: {}, credentials_provider: {}, scopes: [])
        # A PUT upsert by foreign_id sets identity on the record before
        # assignment; a blank body value must not wipe it.
        base.delete(:foreign_id) if base[:foreign_id].blank? && ref.foreign_id.present?
        base.delete(:namespace) if base[:namespace].blank? && ref.namespace.present?
        base[:namespace] = "default" if base[:namespace].blank? && ref.namespace.blank?

        keyfile_attrs = if attrs.key?(:keyfile) && attrs[:keyfile].present?
          attrs.require(:keyfile).permit(:source_type, :secret, config: {})
        end

        rules_attrs = build_rules(attrs)

        GcpAuthSecret.transaction do
          ref.assign_attributes(base)
          ref.keyfile_source = keyfile_attrs ? SecretSource.new(keyfile_attrs.to_h) : nil
          ref.rules = rules_attrs
          ref.save!
          ref.reload
        end
      end

      def build_rules(attrs)
        Array(attrs[:rules]).each_with_index.map do |r, i|
          permitted = ActionController::Parameters.new(r.to_unsafe_h).permit(:host, :cidr, http_methods: [], paths: [])
          RequestRule.new(permitted.to_h.merge(position: i))
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
          credentials_provider: ref.credentials_provider,
          subject: ref.subject,
          scopes: ref.scopes,
          keyfile: ref.keyfile_source && {
            source_type: ref.keyfile_source.source_type,
            config: ref.keyfile_source.config
          },
          rules: ref.rules.map do |r|
            { host: r.host, cidr: r.cidr, position: r.position, http_methods: r.http_methods, paths: r.paths }
          end,
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
