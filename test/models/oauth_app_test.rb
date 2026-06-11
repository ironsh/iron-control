require "test_helper"

class OauthAppTest < ActiveSupport::TestCase
  def build_app(**overrides)
    OauthApp.new({
      namespace: "default", foreign_id: "app-#{SecureRandom.hex(4)}",
      provider: "google", client_id: "cid", client_secret: "sec",
      allowed_scopes: %w[scope.a scope.b],
      allowed_return_urls: %w[https://app.example/cb],
      credential_namespace: "default", created_by: users(:acme_admin)
    }.merge(overrides))
  end

  # --- validations ----------------------------------------------------------

  test "valid with all required fields" do
    assert build_app.valid?
  end

  test "provider must be a registered provider" do
    refute build_app(provider: "github").valid?
    assert build_app(provider: "google").valid?
  end

  test "client_id and client_secret are required" do
    refute build_app(client_id: nil).valid?
    refute build_app(client_secret: nil).valid?
  end

  test "namespace and credential_namespace must be url-safe" do
    refute build_app(namespace: "not safe").valid?
    refute build_app(credential_namespace: "not/safe").valid?
  end

  test "allowed_scopes must be a non-empty array of non-blank strings" do
    refute build_app(allowed_scopes: []).valid?
    refute build_app(allowed_scopes: [ "" ]).valid?
    refute build_app(allowed_scopes: "scope.a").valid?
    assert build_app(allowed_scopes: %w[scope.a]).valid?
  end

  test "allowed_return_urls must be non-empty absolute http(s) urls" do
    refute build_app(allowed_return_urls: []).valid?
    refute build_app(allowed_return_urls: [ "not-a-url" ]).valid?
    refute build_app(allowed_return_urls: [ "ftp://app.example/cb" ]).valid?
    refute build_app(allowed_return_urls: [ "/relative" ]).valid?
  end

  test "http return urls allowed only for localhost / 127.0.0.1" do
    refute build_app(allowed_return_urls: [ "http://app.example/cb" ]).valid?
    assert build_app(allowed_return_urls: [ "http://localhost:3000/cb" ]).valid?
    assert build_app(allowed_return_urls: [ "http://127.0.0.1:3000/cb" ]).valid?
  end

  test "client_secret is encrypted at rest" do
    app = build_app(client_secret: "shh")
    app.save!
    raw = OauthApp.connection.select_value("SELECT client_secret FROM oauth_apps WHERE id = #{app.id}")
    refute_includes raw.to_s, "shh"
    assert_equal "shh", app.reload.client_secret
  end

  # --- return_url_allowed? boundary cases -----------------------------------

  test "return_url_allowed? exact match" do
    app = build_app(allowed_return_urls: [ "https://app.example/cb" ])
    assert app.return_url_allowed?("https://app.example/cb")
  end

  test "return_url_allowed? prefix ending in slash matches sub-paths" do
    app = build_app(allowed_return_urls: [ "https://app.example/" ])
    assert app.return_url_allowed?("https://app.example/anything/here")
  end

  test "return_url_allowed? does not match a sibling domain" do
    app = build_app(allowed_return_urls: [ "https://app.example" ])
    refute app.return_url_allowed?("https://app.example.evil.com")
  end

  test "return_url_allowed? matches only at a path boundary" do
    app = build_app(allowed_return_urls: [ "https://app.example/cb" ])
    assert app.return_url_allowed?("https://app.example/cb?x=1")
    assert app.return_url_allowed?("https://app.example/cb/done")
    assert app.return_url_allowed?("https://app.example/cb#frag")
    refute app.return_url_allowed?("https://app.example/cbevil")
  end

  test "return_url_allowed? false for blank" do
    refute build_app.return_url_allowed?(nil)
    refute build_app.return_url_allowed?("")
  end

  # --- scopes_allowed? ------------------------------------------------------

  test "scopes_allowed? subset check" do
    app = build_app(allowed_scopes: %w[a b c])
    assert app.scopes_allowed?(%w[a b])
    assert app.scopes_allowed?([])
    refute app.scopes_allowed?(%w[a z])
  end

  test "default_return_url is the first allowlist entry" do
    app = build_app(allowed_return_urls: %w[https://one.example/cb https://two.example/cb])
    assert_equal "https://one.example/cb", app.default_return_url
  end

  # --- delete guard ---------------------------------------------------------

  test "cannot be destroyed while it has minted credentials" do
    app = build_app
    app.save!
    BrokerCredential.create!(namespace: "default", foreign_id: "minted-#{SecureRandom.hex(4)}",
                             token_endpoint: "https://oauth2.googleapis.com/token",
                             oauth_app: app, provider_subject: "sub-1")
    refute app.destroy
    assert app.errors[:base].any?
    assert OauthApp.exists?(app.id)
  end
end
