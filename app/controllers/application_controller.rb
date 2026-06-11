class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # UI-wide 404 for record lookups (find_by_oid! and friends), so console
  # controllers don't each hand-roll a rescue. Mirrors Api::BaseController.
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  helper_method :current_user
  helper_method :public_base_url, :oauth_callback_redirect_uri

  # The public origin iron-control is reached at. Derived from the request by
  # default; IRON_CONTROL_PUBLIC_URL overrides it for deployments behind proxies
  # whose Host header doesn't match the public origin. Shared by the OAuth flow
  # controller (the redirect URI it sends the IdP) and the console (the redirect
  # URI / start-URL template it shows operators), so the two never drift.
  def public_base_url
    ENV["IRON_CONTROL_PUBLIC_URL"].presence || request.base_url
  end

  # The OAuth callback redirect URI registered with the IdP for an app:
  # "<public base>/oauth/<slug>/callback". One per app, keyed by its slug.
  def oauth_callback_redirect_uri(slug)
    URI.join(public_base_url, "/oauth/#{slug}/callback").to_s
  end

  # Gate every UI route behind a console session by default. Controllers that
  # must stay reachable while signed out (e.g. the login form) skip this. API
  # controllers descend from ActionController::API, not this class, so they keep
  # their own ApiKey/proxy-token auth and are unaffected.
  before_action :require_login

  private

  # The signed-in operator for cookie-session (console) requests, or nil. Distinct
  # from Api::BaseController#current_user, which resolves a User from an API key.
  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  # before_action gate for console pages: bounce anonymous requests to the login
  # form rather than rendering the page.
  def require_login
    redirect_to login_path unless current_user
  end

  def render_not_found(e)
    render plain: e.message, status: :not_found
  end
end
