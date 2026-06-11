require "test_helper"

module Oauth
  # Covers the public consent flow end to end: /start builds the IdP redirect and
  # binds the browser, /callback exchanges the code and upserts a BrokerCredential.
  # The IdP is faked by swapping the controller's exchange_client_factory for a
  # client wrapped around an HTTP double returning a canned token response.
  class FlowsControllerTest < ActionDispatch::IntegrationTest
    CLIENT_ID = "acme-google-client-id".freeze

    setup do
      @app = oauth_apps(:acme_google)
      @app.update!(client_secret: "app-secret")
    end

    teardown do
      # exchange_client_factory is a class_attribute; restore the default so a
      # swap in one test can't leak into another.
      FlowsController.exchange_client_factory = -> { Broker::AuthorizationCodeClient.new }
    end

    # An HTTP double matching the AuthorizationCodeClient contract.
    class StubHTTP
      def initialize(status:, body:)
        @status = status
        @body = body
      end

      def call(url:, form:, headers:, timeout:)
        Broker::AuthorizationCodeClient::Response.new(status: @status, body: @body)
      end
    end

    def stub_exchange(status:, body:)
      FlowsController.exchange_client_factory = -> { Broker::AuthorizationCodeClient.new(http: StubHTTP.new(status: status, body: body)) }
    end

    def id_token(claims)
      "h.#{Base64.urlsafe_encode64(claims.to_json, padding: false)}.s"
    end

    def token_body(sub: "google-sub-1", email: "user@example.com", aud: CLIENT_ID,
                   iss: "https://accounts.google.com", scope: "https://www.googleapis.com/auth/gmail.readonly openid", **overrides)
      {
        access_token: "AT", refresh_token: "RT", expires_in: 3600, scope: scope,
        id_token: id_token({ "aud" => aud, "iss" => iss, "sub" => sub, "email" => email })
      }.merge(overrides).to_json
    end

    # Runs /start and returns the state extracted from the IdP redirect (the flow
    # cookie is set in the shared integration cookie jar as a side effect).
    def start_flow(app: @app.oid, **params)
      get oauth_start_url(provider: "google"), params: { app: app }.merge(params)
      assert_response :redirect
      query = URI.parse(response.location).query
      URI.decode_www_form(query).to_h.fetch("state")
    end

    # --- start ----------------------------------------------------------------

    test "start redirects to Google with the right params and sets the flow cookie" do
      get oauth_start_url(provider: "google"), params: {
        app: @app.oid, user: "end-user-1", return_to: "https://app.acme.example/oauth/callback"
      }
      assert_response :redirect
      uri = URI.parse(response.location)
      assert_equal "accounts.google.com", uri.host
      q = URI.decode_www_form(uri.query).to_h
      assert_equal CLIENT_ID, q["client_id"]
      assert_equal "http://www.example.com/oauth/google/callback", q["redirect_uri"]
      assert_equal "code", q["response_type"]
      assert_equal "offline", q["access_type"]
      assert_equal "consent", q["prompt"]
      assert_equal "S256", q["code_challenge_method"]
      assert q["code_challenge"].present?
      # requested ∪ identity scopes
      scopes = q["scope"].split
      assert_includes scopes, "https://www.googleapis.com/auth/gmail.readonly"
      assert_includes scopes, "openid"
      assert_includes scopes, "https://www.googleapis.com/auth/userinfo.email"
      # state is a verifiable signed token
      state = Rails.application.message_verifier(FlowsController::STATE_PURPOSE)
                   .verified(q["state"], purpose: FlowsController::STATE_PURPOSE)
      assert_equal @app.oid, state["app"]
      assert_equal "end-user-1", state["user"]
      assert response.cookies["oauth_flow"].present?
    end

    test "start works without any session" do
      # No login performed: the public flow must be reachable while signed out.
      get oauth_start_url(provider: "google"), params: { app: @app.oid }
      assert_response :redirect
      assert_nil session[:user_id]
    end

    test "start resolves the app by namespace/foreign_id" do
      get oauth_start_url(provider: "google"), params: { app: "acme/google-app" }
      assert_response :redirect
      assert_equal "accounts.google.com", URI.parse(response.location).host
    end

    test "start 404s an unknown provider" do
      get oauth_start_url(provider: "github"), params: { app: @app.oid }
      assert_response :not_found
    end

    test "start 404s an unknown app" do
      get oauth_start_url(provider: "google"), params: { app: "oap_doesnotexist" }
      assert_response :not_found
    end

    test "start 422s a disabled app without redirecting" do
      disabled = oauth_apps(:acme_google_disabled)
      get oauth_start_url(provider: "google"), params: { app: disabled.oid }
      assert_response :unprocessable_entity
    end

    test "start 422s a scope outside the allowlist" do
      get oauth_start_url(provider: "google"), params: { app: @app.oid, scopes: "https://www.googleapis.com/auth/drive" }
      assert_response :unprocessable_entity
    end

    test "start 422s a return_to outside the allowlist" do
      get oauth_start_url(provider: "google"), params: { app: @app.oid, return_to: "https://evil.example/cb" }
      assert_response :unprocessable_entity
    end

    test "start 422s a malformed user key" do
      get oauth_start_url(provider: "google"), params: { app: @app.oid, user: "not a valid key" }
      assert_response :unprocessable_entity
    end

    # --- callback -------------------------------------------------------------

    test "callback happy path mints a live credential and redirects to the app" do
      state = start_flow(user: "end-user-1", return_to: "https://app.acme.example/oauth/callback?ref=abc")
      stub_exchange(status: 200, body: token_body)

      assert_difference -> { BrokerCredential.count } => 1 do
        get oauth_callback_url(provider: "google"), params: { state: state, code: "auth-code" }
      end
      assert_response :redirect

      uri = URI.parse(response.location)
      assert_equal "app.acme.example", uri.host
      q = URI.decode_www_form(uri.query).to_h
      assert_equal "abc", q["ref"] # preserves existing query params
      assert_equal "success", q["oauth"]

      cred = BrokerCredential.find_by_oid(q["credential"])
      assert_equal @app, cred.oauth_app
      assert_equal "acme", cred.namespace
      assert_equal "google-app", @app.foreign_id
      assert_equal "google-google-app-google-sub-1", cred.foreign_id
      assert_equal "https://oauth2.googleapis.com/token", cred.token_endpoint
      assert_equal "google-sub-1", cred.provider_subject
      assert_equal "user@example.com", cred.provider_email
      assert_equal "end-user-1", cred.external_user_key
      assert_equal %w[https://www.googleapis.com/auth/gmail.readonly openid], cred.scopes
      assert_equal "live", cred.status
      assert_equal "AT", cred.access_token
      assert_equal "RT", cred.refresh_token
      assert cred.next_attempt_at.present?
      assert_nil cred.created_by
    end

    test "re-consent for the same account updates the existing credential and revives a dead one" do
      state1 = start_flow
      stub_exchange(status: 200, body: token_body(email: "old@example.com"))
      get oauth_callback_url(provider: "google"), params: { state: state1, code: "code-1" }
      cred = BrokerCredential.find_by_oid(URI.decode_www_form(URI.parse(response.location).query).to_h["credential"])
      cred.update!(dead: true, dead_reason: "invalid_grant")

      state2 = start_flow
      stub_exchange(status: 200, body: token_body(email: "new@example.com"))
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: state2, code: "code-2" }
      end
      cred.reload
      assert_equal "new@example.com", cred.provider_email
      refute cred.dead?
      assert_equal "live", cred.status
    end

    test "callback with error=access_denied redirects denied and mints nothing" do
      state = start_flow(return_to: "https://app.acme.example/oauth/callback")
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: state, error: "access_denied" }
      end
      q = URI.decode_www_form(URI.parse(response.location).query).to_h
      assert_equal "denied", q["oauth"]
      assert_equal "access_denied", q["error"]
    end

    test "callback with tampered state is a 400 and mints nothing" do
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: "tampered", code: "x" }
      end
      assert_response :bad_request
    end

    test "callback with a missing flow cookie is a 400" do
      # Self-sign a valid state without running /start, so no flow cookie exists.
      state = Rails.application.message_verifier(FlowsController::STATE_PURPOSE).generate(
        { "app" => @app.oid, "user" => nil, "scopes" => Array(@app.allowed_scopes),
          "return_to" => @app.default_return_url, "nonce" => "some-nonce" },
        purpose: FlowsController::STATE_PURPOSE, expires_in: 10.minutes
      )
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: state, code: "x" }
      end
      assert_response :bad_request
    end

    test "callback exchange failure redirects error and mints nothing" do
      state = start_flow(return_to: "https://app.acme.example/oauth/callback")
      stub_exchange(status: 400, body: { error: "invalid_grant" }.to_json)
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: state, code: "bad-code" }
      end
      q = URI.decode_www_form(URI.parse(response.location).query).to_h
      assert_equal "error", q["oauth"]
      assert_equal "invalid_grant", q["error"]
    end

    test "callback with id_token aud mismatch is treated as an error" do
      state = start_flow(return_to: "https://app.acme.example/oauth/callback")
      stub_exchange(status: 200, body: token_body(aud: "someone-else"))
      assert_no_difference -> { BrokerCredential.count } do
        get oauth_callback_url(provider: "google"), params: { state: state, code: "code" }
      end
      q = URI.decode_www_form(URI.parse(response.location).query).to_h
      assert_equal "error", q["oauth"]
      assert_equal "id_token_aud_mismatch", q["error"]
    end

    test "callback when the app was deleted between start and callback is a 400" do
      state = start_flow
      @app.destroy!
      get oauth_callback_url(provider: "google"), params: { state: state, code: "code" }
      assert_response :bad_request
    end
  end
end
