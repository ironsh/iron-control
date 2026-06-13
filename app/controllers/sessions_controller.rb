# Quick session-cookie login for the operator console. Authenticates an existing
# User (has_secure_password) by email + password and stores their id in the
# session. No registration, password reset, or rate limiting: this is an internal
# gate, not a public auth system.
class SessionsController < ApplicationController
  layout "auth"

  # The login form must be reachable while signed out, so it opts out of the
  # app-wide require_login gate. (logout keeps the gate: it's a no-op when
  # there's no session.)
  skip_before_action :require_login, only: %i[new create]
  # None of these enforce approval: the login form is anonymous, and pending users
  # must still reach the holding page and be able to sign out.
  skip_before_action :require_active_account

  def new
    redirect_to console_principals_path if current_user&.active?
  end

  # Holding page for a signed-in but not-yet-approved user. Active users have no
  # reason to be here, so send them to the console.
  def pending
    redirect_to console_principals_path if current_user&.active?
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    unless user&.authenticate(params[:password])
      flash.now[:alert] = "Invalid email or password."
      return render :new, status: :unprocessable_entity
    end

    if user.disabled?
      flash.now[:alert] = "Your account is disabled."
      return render :new, status: :unprocessable_entity
    end

    reset_session
    session[:user_id] = user.id
    if user.active?
      redirect_to console_principals_path, notice: "Signed in as #{user.email}."
    else
      redirect_to pending_path, notice: "Your account is awaiting approval."
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end
end
