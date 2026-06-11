require "base64"
require "digest"
require "uri"

module Oauth
  # The public OAuth consent flow: /oauth/:provider/start sends an end user to the
  # IdP's consent screen, and /oauth/:provider/callback turns the returned
  # authorization code into a managed BrokerCredential linked to the OauthApp.
  #
  # Deliberately unauthenticated -- end users of customer apps reach these, not
  # console operators. Safety comes from: a credential is only minted after a
  # successful consent + code exchange; return URLs are allowlisted per app;
  # re-consent for the same (app, provider account) upserts the existing
  # credential rather than creating a new one. All provider-specific behavior
  # comes from the strategy (Oauth::Providers).
  #
  # SECURITY: never logs the code, tokens, client_secret, or response bodies --
  # only oids and error codes, like the rest of the Broker/Oauth subsystem.
  class FlowsController < ApplicationController
    skip_before_action :require_login

    # The message_verifier purpose binding the signed state to this flow, the
    # state/cookie lifetime, and the encrypted cookie that ties a callback back to
    # the browser that started it.
    STATE_PURPOSE = :oauth_consent_flow
    FLOW_TTL = 10.minutes
    FLOW_COOKIE = :oauth_flow

    # Tests swap in an AuthorizationCodeClient built around an http double,
    # mirroring BrokerCredential#refresh_client.
    class_attribute :exchange_client_factory, default: -> { Broker::AuthorizationCodeClient.new }

    before_action :set_strategy

    # GET /oauth/:provider/start?app=&user=&scopes=&return_to=
    def start
      app = resolve_app(params[:app])
      return render_flow_error(:not_found, "unknown oauth app") if app.nil?
      return render_flow_error(:unprocessable_entity, "oauth app is for a different provider") unless app.provider == @provider.key
      return render_flow_error(:unprocessable_entity, "oauth app is disabled") unless app.enabled?

      user_key = params[:user].presence
      if user_key && !valid_user_key?(user_key)
        return render_flow_error(:unprocessable_entity, "user must be url-safe and at most 128 characters")
      end

      requested_scopes = parse_scopes(params[:scopes]) || Array(app.allowed_scopes)
      unless app.scopes_allowed?(requested_scopes)
        return render_flow_error(:unprocessable_entity, "one or more requested scopes are not allowed")
      end

      return_to = params[:return_to].presence || app.default_return_url
      unless app.return_url_allowed?(return_to)
        return render_flow_error(:unprocessable_entity, "return_to is not in the allowlist")
      end

      nonce = SecureRandom.urlsafe_base64(32)
      code_verifier = SecureRandom.urlsafe_base64(64)

      state = Rails.application.message_verifier(STATE_PURPOSE).generate(
        { "app" => app.oid, "user" => user_key, "scopes" => requested_scopes,
          "return_to" => return_to, "nonce" => nonce },
        purpose: STATE_PURPOSE, expires_in: FLOW_TTL
      )

      # :lax is required -- the callback arrives via a top-level cross-site
      # redirect from the IdP, which Lax permits for GET.
      cookies.encrypted[FLOW_COOKIE] = {
        value: { "nonce" => nonce, "code_verifier" => code_verifier }.to_json,
        expires: FLOW_TTL.from_now, httponly: true, same_site: :lax
      }

      redirect_to authorization_url(app, requested_scopes, state, code_verifier), allow_other_host: true
    end

    # GET /oauth/:provider/callback?code=&state=  (or ?error=)
    def callback
      state = Rails.application.message_verifier(STATE_PURPOSE).verified(params[:state], purpose: STATE_PURPOSE)
      return render_flow_error(:bad_request, "invalid, tampered, or expired state") if state.nil?

      # Re-resolve the app from the signed state. If the row is gone we can no
      # longer prove the allowlist still covers return_to, so render plain text
      # rather than redirect.
      app = OauthApp.find_by_oid(state["app"])
      if app.nil? || !app.enabled? || app.provider != @provider.key
        return render_flow_error(:bad_request, "oauth app is no longer available for this flow")
      end

      flow = read_and_clear_flow_cookie
      if flow.nil? || flow["nonce"] != state["nonce"]
        return render_flow_error(:bad_request, "flow expired or started in another browser — restart the flow")
      end

      return_to = state["return_to"]

      # The user declined (or another IdP-side error). Bounce back to the app.
      if params[:error].present?
        return redirect_back_to_app(return_to, oauth: "denied", error: params[:error])
      end

      result = exchange_code(app, params[:code], flow["code_verifier"])
      identity = @provider.identity_from(result, client_id: app.client_id)
      credential = upsert_credential(app, state, result, identity)

      redirect_back_to_app(return_to, oauth: "success", credential: credential.oid)
    rescue Broker::ExchangeError => e
      redirect_back_to_app(return_to, oauth: "error", error: e.reason)
    rescue ActiveRecord::RecordInvalid => e
      # Most likely the deterministic foreign_id collides with an unrelated
      # credential. Log the messages only -- never token values.
      Rails.logger.error { "oauth flow credential save failed: #{e.record.errors.full_messages.to_sentence}" }
      redirect_back_to_app(return_to, oauth: "error", error: "credential_save_failed")
    end

    private

    def set_strategy
      @provider = Oauth::Providers.fetch(params[:provider])
      render plain: "unknown oauth provider", status: :not_found if @provider.nil?
    end

    # The app is addressed by its oid (oap_…) or by "<namespace>/<foreign_id>"
    # (anything containing a "/").
    def resolve_app(identifier)
      return nil if identifier.blank?
      if identifier.include?("/")
        namespace, foreign_id = identifier.split("/", 2)
        return nil if namespace.blank? || foreign_id.blank?
        OauthApp.find_by(namespace: namespace, foreign_id: foreign_id)
      else
        OauthApp.find_by_oid(identifier)
      end
    end

    def valid_user_key?(key)
      key.length <= 128 && key.match?(OauthApp::URL_SAFE_FORMAT)
    end

    # Accepts space- or comma-separated scope lists; nil when none were given
    # (the caller defaults to the app's full allowlist).
    def parse_scopes(raw)
      return nil if raw.blank?
      raw.split(/[,\s]+/).map(&:strip).reject(&:blank?)
    end

    def authorization_url(app, requested_scopes, state, code_verifier)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
      query = {
        "client_id" => app.client_id,
        "redirect_uri" => oauth_callback_redirect_uri(@provider.key),
        "response_type" => "code",
        "scope" => (requested_scopes | @provider.identity_scopes).join(" "),
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      }.merge(@provider.extra_authorization_params)

      uri = URI.parse(@provider.authorization_endpoint)
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end

    def exchange_code(app, code, code_verifier)
      exchange_client_factory.call.exchange(
        token_endpoint: @provider.token_endpoint,
        client_id: app.client_id,
        client_secret: app.client_secret,
        code: code.to_s,
        redirect_uri: oauth_callback_redirect_uri(@provider.key),
        code_verifier: code_verifier.to_s
      )
    end

    # Upserts one credential per (app, provider account). A new record gets its
    # identity/endpoint fixed; every consent (re)applies the rotating blob,
    # including the freshly-exchanged access token so the credential is live
    # immediately, and revives a dead credential.
    def upsert_credential(app, state, result, identity)
      BrokerCredential.transaction do
        credential = BrokerCredential.find_or_initialize_by(oauth_app: app, provider_subject: identity[:subject])
        if credential.new_record?
          app_handle = app.foreign_id.presence || app.oid
          credential.namespace = app.credential_namespace
          credential.foreign_id = "#{app.provider}-#{app_handle}-#{identity[:subject]}"
          credential.name = "#{app.provider.capitalize} – #{identity[:email]}"
          credential.token_endpoint = @provider.token_endpoint
        end

        now = Time.current
        expires_in = result.expires_in&.positive? ? result.expires_in : BrokerCredential::DEFAULT_EXPIRES_IN_SECONDS
        credential.assign_attributes(
          provider_email: identity[:email],
          external_user_key: state["user"].presence || credential.external_user_key,
          # Store exactly what the IdP granted, so the refresh POST re-requests it.
          scopes: (result.scope.presence&.split || Array(state["scopes"])),
          refresh_token: result.refresh_token,
          access_token: result.access_token,
          expires_at: now + expires_in,
          last_refresh: now,
          failure_count: 0, dead: false, dead_reason: nil
        )
        credential.next_attempt_at = credential.compute_next_attempt_at(now: now)
        credential.save!
        credential
      end
    end

    # Appends params to return_to's existing query string. return_to came out of
    # the signed state and was allowlist-checked at /start, so it is trusted here.
    def redirect_back_to_app(return_to, extra_params)
      uri = URI.parse(return_to)
      pairs = uri.query.present? ? URI.decode_www_form(uri.query) : []
      extra_params.each { |k, v| pairs << [ k.to_s, v.to_s ] }
      uri.query = URI.encode_www_form(pairs)
      redirect_to uri.to_s, allow_other_host: true
    end

    def read_and_clear_flow_cookie
      raw = cookies.encrypted[FLOW_COOKIE]
      cookies.delete(FLOW_COOKIE)
      return nil if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def render_flow_error(status, message)
      render plain: message, status: status
    end
  end
end
