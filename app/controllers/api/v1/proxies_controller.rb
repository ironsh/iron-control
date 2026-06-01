module Api
  module V1
    class ProxiesController < Api::BaseController
      def index
        scope = ::Proxy.all
        scope = scope.where(principal: principal_filter) if params[:principal_id].present?
        scope = scope.order(created_at: :asc, id: :asc)

        limit = pagination_limit
        page = pagination_page
        total = scope.count
        records = scope.limit(limit).offset((page - 1) * limit)
        total_pages = total.zero? ? 0 : ((total + limit - 1) / limit)
        render json: {
          data: records.map { |p| record_payload(p) },
          meta: { page: page, limit: limit, total: total, total_pages: total_pages }
        }
      end

      def show
        proxy = ::Proxy.find_by_oid!(params[:id])
        render json: { data: record_payload(proxy) }
      end

      def create
        attrs = data_params.permit(:name, :principal_id)
        principal = Principal.find_by_oid!(attrs[:principal_id])
        proxy = ::Proxy.new(name: attrs[:name], principal: principal)
        proxy.save!
        render status: :created, json: { data: record_payload(proxy).merge(token: proxy.token) }
      rescue ActiveRecord::RecordInvalid => e
        render_validation_error(e.record)
      end

      def destroy
        proxy = ::Proxy.find_by_oid!(params[:id])
        proxy.destroy!
        head :no_content
      end

      private

      def principal_filter
        Principal.find_by_oid!(params[:principal_id])
      end

      def record_payload(proxy)
        {
          id: proxy.oid,
          name: proxy.name,
          principal_id: proxy.principal.oid,
          created_at: proxy.created_at,
          updated_at: proxy.updated_at
        }
      end

      def render_validation_error(record)
        render status: :unprocessable_entity,
               json: { error: { message: "validation failed", details: record.errors.as_json } }
      end
    end
  end
end
