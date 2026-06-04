module Api
  module V1
    # Vends the current access token for a managed BrokerCredential to iron-proxy.
    # The in-control port of iron-token-broker's GET /credentials/{id}/access_token
    # (http.go). Authenticated with the proxy's iprx_ bearer token.
    #
    # The response body is the raw { access_token, expires_at } shape iron-proxy's
    # token_broker resolver decodes -- deliberately NOT the {data:...} envelope the
    # rest of the API uses, because the proxy contract predates this integration.
    class CredentialsController < Api::ProxyBaseController
      def access_token
        # Token material must never be cached by an intermediary or client.
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"

        credential = BrokerCredential.find_by_oid(params[:id])
        return render(status: :not_found, json: { error: "credential not found" }) unless credential

        token, expires_at = credential.access_token!
        render json: { access_token: token, expires_at: expires_at.utc.iso8601 }
      rescue Broker::DeadError => e
        render status: :unprocessable_entity, json: { error: "credential dead", reason: e.reason }
      rescue Broker::NotReadyError
        response.headers["Retry-After"] = "5"
        render status: :service_unavailable, json: { error: "bootstrapping" }
      end
    end
  end
end
