require "test_helper"

class ConsoleControllerTest < ActionDispatch::IntegrationTest
  setup do
    @operator = users(:acme_admin)
    post login_url, params: { email: @operator.email, password: "password123456" }
  end

  test "redirects to login when not signed in" do
    delete logout_url
    get console_principals_url
    assert_redirected_to login_path
  end

  test "secrets table shows backend labels (not refs) and links to detail" do
    secret = static_secrets(:acme_prod_api_key)
    get console_secrets_url
    assert_response :ok
    # Source column shows only the backend label, not the underlying reference.
    assert_select "td span", text: "Env"
    assert_select "body", text: /GITHUB_TOKEN/, count: 0
    # The foreign_id links to the detail page (full value as a hover tooltip),
    # with the opaque oid and namespace shown beneath it.
    assert_select "a[href=?][title=?]", console_secret_path("static", secret.oid), secret.foreign_id
    assert_select "div", text: /#{Regexp.escape(secret.oid)}.*#{Regexp.escape(secret.namespace)}/
    # The name is plain text (not a link) with the full value as a tooltip.
    assert_select "span[title=?]", secret.name
  end

  test "secret detail page shows the full source reference" do
    secret = oauth_token_secrets(:acme_gmail_oauth)
    get console_secret_url("oauth_token", secret.oid)
    assert_response :ok
    assert_select "h1", text: secret.name
    # The full reference is hidden from the table but shown here.
    assert_select "td", text: "GMAIL_CLIENT_ID"
    assert_select "td", text: "op://eng/gmail/refresh-token"
  end

  test "secret detail page renders for every secret kind" do
    [
      [ "static", static_secrets(:github_token_inject) ],
      [ "gcp_auth", gcp_auth_secrets(:acme_gcs_keyfile) ],   # keyfile source
      [ "gcp_auth", gcp_auth_secrets(:acme_bigquery) ],      # workload_identity provider
      [ "oauth_token", oauth_token_secrets(:acme_gmail_oauth) ],
      [ "pg_dsn", pg_dsn_secrets(:acme_analytics_pg) ],
      [ "hmac", hmac_secrets(:acme_webhook_hmac) ]
    ].each do |kind, secret|
      get console_secret_url(kind, secret.oid)
      assert_response :ok, "expected #{kind} detail page for #{secret.oid} to render"
    end
  end

  test "secret detail page 404s for an unknown kind or id" do
    get console_secret_url("bogus", "ssr_whatever")
    assert_response :not_found
    get console_secret_url("static", "ssr_missing")
    assert_response :not_found
  end

  test "principals table combines id with foreign_id over the oid" do
    principal = principals(:acme_channel)
    get console_principals_url
    assert_response :ok
    # foreign_id is the primary line (with a hover tooltip); the oid and
    # namespace sit beneath it.
    assert_select "div[title=?]", principal.foreign_id, text: principal.foreign_id
    assert_select "div", text: /#{Regexp.escape(principal.oid)}.*#{Regexp.escape(principal.namespace)}/
  end

  test "credentials table combines id, shows status, and links to detail" do
    credential = broker_credentials(:acme_managed_gmail)
    get console_credentials_url
    assert_response :ok
    assert_select "a[href=?][title=?]", console_credential_path(credential.oid), credential.foreign_id
    assert_select "div", text: /#{Regexp.escape(credential.oid)}.*#{Regexp.escape(credential.namespace)}/
    assert_select "span", text: credential.status
  end

  test "credential detail page shows refresh and client data" do
    credential = broker_credentials(:acme_managed_gmail)
    get console_credential_url(credential.oid)
    assert_response :ok
    assert_select "h1", text: credential.name
    # The next-refresh data lives here now (removed from the index table).
    assert_select "dt", text: "Next attempt"
    assert_select "dd", text: credential.client_id
    assert_select "dd", text: credential.token_endpoint
    # Token material is never rendered.
    assert_select "body", text: /access[_ ]token/i, count: 0
  end

  test "credential detail page 404s for an unknown id" do
    get console_credential_url("bcr_missing")
    assert_response :not_found
  end

  test "header shows the signed-in operator and a sign-out control" do
    get console_principals_url
    assert_response :ok
    assert_select "span", text: @operator.email
    assert_select "form[action=?][method=?]", logout_path, "post" do
      assert_select "input[name=_method][value=delete]", count: 1
      assert_select "button", text: "Sign out"
    end
  end
end
