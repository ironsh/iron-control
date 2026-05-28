module Api
  module V1
    class StaticSecretsController < Api::BaseController
      def index
        records, meta = paginated_label_search(StaticSecret.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        ref = StaticSecret.find_by_oid!(params[:id])
        render json: { data: record_payload(ref) }
      end

      def create
        ref = StaticSecret.new(created_by: current_user)
        upsert!(ref, data_params)
        render status: :created, json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        ref = StaticSecret.find_by_oid!(params[:id])
        upsert!(ref, data_params)
        render json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      private

      def upsert!(ref, attrs)
        ss_attrs = attrs.permit(
          :namespace, :foreign_id, :name, :description,
          labels: {}, inject_config: {}, replace_config: {}
        )
        ss_attrs[:namespace] = "default" if ref.new_record? && ss_attrs[:namespace].blank?

        source_attrs = if attrs.key?(:source) && attrs[:source].present?
          attrs.require(:source).permit(:source_type, :secret, config: {})
        end

        rules_attrs = Array(attrs[:rules]).map do |r|
          ActionController::Parameters.new(r.to_unsafe_h).permit(
            :host, :cidr, http_methods: [], paths: []
          )
        end

        StaticSecret.transaction do
          ref.assign_attributes(ss_attrs)
          ref.save!

          ref.source&.destroy!
          if source_attrs
            SecretSource.create!(source_attrs.to_h.merge(static_secret: ref))
          end

          ref.rules.destroy_all
          rules_attrs.each_with_index do |r, i|
            RequestRule.create!(r.to_h.merge(position: i, static_secret: ref))
          end

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
          inject_config: ref.inject_config,
          replace_config: ref.replace_config,
          source: ref.source && {
            source_type: ref.source.source_type,
            config: ref.source.config
          },
          rules: ref.rules.map do |r|
            {
              host: r.host,
              cidr: r.cidr,
              position: r.position,
              http_methods: r.http_methods,
              paths: r.paths
            }
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
