module Api
  module V1
    # POST /api/v1/proxy/sync
    #
    # iron-proxy polls this endpoint to fetch its config. It sends its current
    # config_hash; when that matches the freshly computed hash we return only the
    # hash (no payload), so the proxy skips re-applying. Otherwise we return the
    # full `secrets` and `transforms` payload.
    #
    # `secrets` populates the proxy's `secrets` transform. `transforms` carries
    # whole transforms the proxy splices into its pipeline: a gcp_auth transform
    # per granted GcpAuthSecret and one bundled oauth_token transform.
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
          # status and principal_id let an unassigned proxy tell "no config yet"
          # apart from "config is genuinely empty", and let it detect a swap.
          render json: {
            config_hash: current_hash,
            status: current_proxy.status,
            principal_id: current_proxy.principal&.oid,
            secrets: current_proxy.sync_secrets,
            transforms: current_proxy.sync_transforms
          }
        end
      end
    end
  end
end
