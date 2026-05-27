module Api
  class BaseController < ActionController::API
    before_action :authenticate_api_key!

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActionController::ParameterMissing, with: :render_bad_request

    attr_reader :current_api_key

    def current_user
      current_api_key&.user
    end

    private

    def authenticate_api_key!
      token = bearer_token
      @current_api_key = ApiKey.find_by_token(token) if token.present?
      return if @current_api_key

      render_error(status: :unauthorized, message: "invalid or missing API key")
    end

    def bearer_token
      header = request.headers["Authorization"].to_s
      return nil unless header.start_with?("Bearer ")
      header.sub(/\ABearer\s+/, "").presence
    end

    def render_error(status:, message:, details: nil)
      body = { error: { message: message } }
      body[:error][:details] = details if details
      render status: status, json: body
    end

    def render_not_found(e)
      render_error(status: :not_found, message: e.message)
    end

    def render_bad_request(e)
      render_error(status: :bad_request, message: e.message)
    end

    def data_params
      params.require(:data)
    end
  end
end
