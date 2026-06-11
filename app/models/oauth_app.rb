# An operator-registered OAuth application: the provider, the OAuth client
# (client_id + encrypted client_secret), and the policy that bounds the public
# consent flows it drives -- which scopes may be requested and which return URLs
# the callback may redirect to.
#
# The unauthenticated /oauth/:provider/start + /callback endpoints resolve an
# OauthApp, run the provider's consent flow, and on success upsert a
# BrokerCredential linked back to this app (see BrokerCredential#oauth_app). The
# app is the durable config; its minted credentials are refreshed by the normal
# Broker::PollRefreshJob loop and delegate their client_id/client_secret back to
# the app, so rotating the app's secret fixes every credential it minted.
#
# Provider-generic by design: one model with a `provider` column and a small
# strategy registry (Oauth::Providers), not a table per provider. Today the only
# provider is Google.
class OauthApp < ApplicationRecord
  oid_prefix "oap"

  include ForeignIdCollisionGuard

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  belongs_to :created_by, class_name: "User"

  # Deleting an app with minted credentials must fail: those credentials
  # delegate their client_id/secret here and would be left unable to refresh.
  # The operator deletes/unlinks the credentials first. Mirrors
  # BrokerCredential#ensure_not_referenced.
  has_many :broker_credentials, dependent: :restrict_with_error

  encrypts :client_secret

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, uniqueness: { scope: :namespace, allow_nil: true },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }, allow_nil: true
  validates :provider, inclusion: { in: ->(_) { Oauth::Providers.keys }, message: "is not a supported provider" }
  validates :client_id, presence: true
  validates :client_secret, presence: true
  validates :credential_namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validate :labels_is_a_hash
  validate :allowed_scopes_valid
  validate :allowed_return_urls_valid

  # The provider strategy backing this app, or nil if the provider column somehow
  # holds an unknown key (the inclusion validation normally prevents that).
  def provider_strategy = Oauth::Providers.fetch(provider)

  # True when +url+ is covered by the allowlist. A prefix only matches at a path
  # boundary: either the prefix itself ends with "/", or the character in +url+
  # immediately after the prefix is one of "/", "?", "#" (or the match is exact).
  # This stops "https://app.example" from matching "https://app.example.evil.com".
  def return_url_allowed?(url)
    return false if url.blank?
    Array(allowed_return_urls).any? do |prefix|
      next false unless url.start_with?(prefix)
      next true if url.length == prefix.length || prefix.end_with?("/")
      "/?#".include?(url[prefix.length])
    end
  end

  # The fallback return URL when the flow omits return_to: the first allowlist
  # entry.
  def default_return_url = Array(allowed_return_urls).first

  # True when every requested scope is within the allowlist.
  def scopes_allowed?(requested) = (Array(requested) - Array(allowed_scopes)).empty?

  private

  def labels_is_a_hash
    errors.add(:labels, "must be a hash") unless labels.is_a?(Hash)
  end

  def allowed_scopes_valid
    unless allowed_scopes.is_a?(Array) && allowed_scopes.any? && allowed_scopes.all? { |s| s.is_a?(String) && s.present? }
      errors.add(:allowed_scopes, "must be a non-empty array of non-blank strings")
    end
  end

  def allowed_return_urls_valid
    unless allowed_return_urls.is_a?(Array) && allowed_return_urls.any?
      errors.add(:allowed_return_urls, "must be a non-empty array")
      return
    end
    allowed_return_urls.each do |entry|
      errors.add(:allowed_return_urls, "entry #{entry.inspect} is not a valid absolute URL") unless valid_return_url?(entry)
    end
  end

  # Each return URL must be an absolute http(s) URL with a host. http is only
  # allowed for localhost / 127.0.0.1 as a development convenience; everything
  # else must be https so the callback never redirects tokens-in-query over
  # plaintext.
  def valid_return_url?(entry)
    return false unless entry.is_a?(String) && entry.present?
    uri = URI.parse(entry)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    return true if uri.scheme == "https"
    uri.scheme == "http" && %w[localhost 127.0.0.1].include?(uri.host)
  rescue URI::InvalidURIError
    false
  end
end
