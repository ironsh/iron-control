require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup { @operator = users(:acme_admin) }

  test "GET new renders the login form" do
    get login_url
    assert_response :ok
    assert_select "form[action=?]", login_path
  end

  test "valid credentials sign in and redirect to the console" do
    post login_url, params: { email: @operator.email, password: "password123456" }
    assert_redirected_to console_principals_path
    assert_equal @operator.id, session[:user_id]
  end

  test "email match is case-insensitive" do
    post login_url, params: { email: @operator.email.upcase, password: "password123456" }
    assert_equal @operator.id, session[:user_id]
  end

  test "invalid password re-renders the form without a session" do
    post login_url, params: { email: @operator.email, password: "wrong" }
    assert_response :unprocessable_entity
    assert_nil session[:user_id]
    assert_select "div", /Invalid email or password/
  end

  test "logout clears the session" do
    post login_url, params: { email: @operator.email, password: "password123456" }
    delete logout_url
    assert_redirected_to login_path
    assert_nil session[:user_id]
  end
end
