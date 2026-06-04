module Api
  module V1
    # Operator CRUD for managed broker credentials. Mirrors the secret
    # controllers (oid/foreign_id addressing, label search, PUT-upsert), with two
    # differences: the initial refresh_token is a write-only seed, and the
    # rotating token blob (access_token/refresh_token) is NEVER serialized back.
    class BrokerCredentialsController < Api::BaseController
      def index
        records, meta = paginated_label_search(BrokerCredential.all)
        render json: { data: records.map { |r| record_payload(r) }, meta: meta }
      end

      def show
        ref = BrokerCredential.find_by_oid!(params[:id])
        render json: { data: record_payload(ref) }
      end

      # GET /api/v1/broker_credentials/lookup/:namespace/:foreign_id
      def lookup
        render json: { data: record_payload(find_by_foreign_id!(BrokerCredential)) }
      end

      def create
        ref = BrokerCredential.new(created_by: current_user)
        assign_and_save!(ref, data_params)
        render status: :created, json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def update
        ref = resolve_for_upsert(BrokerCredential)
        was_new = ref.new_record?
        assign_and_save!(ref, data_params)
        render status: (was_new ? :created : :ok), json: { data: record_payload(ref) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        ref = BrokerCredential.find_by_oid!(params[:id])
        ref.destroy!
        head :no_content
      end

      private

      def assign_and_save!(ref, attrs)
        base = attrs.permit(:namespace, :foreign_id, :name, :description, :token_endpoint,
                            :early_refresh_slack_seconds, :early_refresh_fraction,
                            :max_refresh_interval_seconds, :refresh_timeout_seconds,
                            labels: {}, scopes: [])
        # A PUT upsert by foreign_id sets identity before assignment; a blank body
        # value must not wipe it.
        base.delete(:foreign_id) if base[:foreign_id].blank? && ref.foreign_id.present?
        base.delete(:namespace) if base[:namespace].blank? && ref.namespace.present?
        base[:namespace] = "default" if base[:namespace].blank? && ref.namespace.blank?

        BrokerCredential.transaction do
          ref.assign_attributes(base)
          # Only replace the source graph when the body supplies it, so a partial
          # update (e.g. a refresh_token-only re-auth) preserves existing sources.
          if attrs.key?(:credentials) || attrs.key?(:token_endpoint_headers)
            ref.sources = build_credential_sources(attrs) + build_header_sources(attrs)
          end
          apply_refresh_token_seed(ref, attrs)
          ref.save!
          ref.reload
        end
      end

      # The refresh_token is a write-only bootstrap/re-auth seed. Supplying a new
      # one resets the credential to "due now" and clears any dead state, so the
      # next poll re-bootstraps it. A blank/absent value leaves the existing seed
      # (and rotation state) untouched.
      def apply_refresh_token_seed(ref, attrs)
        seed = attrs[:refresh_token]
        return if seed.blank?

        ref.refresh_token = seed
        ref.dead = false
        ref.dead_reason = nil
        ref.failure_count = 0
        ref.next_attempt_at = Time.current
      end

      def build_credential_sources(attrs)
        return [] unless attrs.key?(:credentials) && attrs[:credentials].present?

        attrs.require(:credentials).each_pair.map do |role, src|
          SecretSource.new(permit_source(src).merge(role: role.to_s, role_kind: "credential_field"))
        end
      end

      def build_header_sources(attrs)
        return [] unless attrs.key?(:token_endpoint_headers) && attrs[:token_endpoint_headers].present?

        attrs.require(:token_endpoint_headers).each_pair.map do |name, src|
          SecretSource.new(permit_source(src).merge(role: name.to_s, role_kind: "endpoint_header"))
        end
      end

      def permit_source(src)
        params = src.is_a?(ActionController::Parameters) ? src : ActionController::Parameters.new(src)
        params.permit(:source_type, :secret, config: {}).to_h
      end

      # Observability only -- access_token and refresh_token are deliberately
      # never included.
      def record_payload(ref)
        cred = ref.sources.select(&:credential_field?)
        headers = ref.sources.select(&:endpoint_header?)
        {
          id: ref.oid,
          namespace: ref.namespace,
          foreign_id: ref.foreign_id,
          name: ref.name,
          description: ref.description,
          labels: ref.labels,
          token_endpoint: ref.token_endpoint,
          scopes: ref.scopes,
          early_refresh_slack_seconds: ref.early_refresh_slack_seconds,
          early_refresh_fraction: ref.early_refresh_fraction,
          max_refresh_interval_seconds: ref.max_refresh_interval_seconds,
          refresh_timeout_seconds: ref.refresh_timeout_seconds,
          credentials: cred.to_h { |s| [ s.role, source_payload(s) ] },
          token_endpoint_headers: headers.to_h { |s| [ s.role, source_payload(s) ] },
          status: ref.status,
          expires_at: ref.expires_at,
          last_refresh: ref.last_refresh,
          next_attempt_at: ref.next_attempt_at,
          dead: ref.dead,
          dead_reason: ref.dead_reason,
          failure_count: ref.failure_count,
          created_at: ref.created_at,
          updated_at: ref.updated_at
        }
      end

      def source_payload(source)
        { source_type: source.source_type, config: source.config }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
