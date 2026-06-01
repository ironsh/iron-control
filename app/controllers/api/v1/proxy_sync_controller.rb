module Api
  module V1
    # POST /api/v1/proxy/sync
    #
    # iron-proxy polls this endpoint to fetch its config. It sends its current
    # config_hash; when that matches the freshly computed hash we return only the
    # hash (no payload), so the proxy skips re-applying. Otherwise we return the
    # full secrets array.
    #
    # The top-level `rules`, `mcp`, and `ingest_token` fields the proxy also
    # understands are intentionally omitted: iron-control has no models for them
    # yet. Each secret still carries its own per-secret `rules`.
    class ProxySyncController < Api::ProxyBaseController
      def create
        current_hash = current_proxy.config_hash

        if params[:config_hash].presence == current_hash
          render json: { config_hash: current_hash }
        else
          render json: { config_hash: current_hash, secrets: current_proxy.sync_secrets }
        end
      end
    end
  end
end
