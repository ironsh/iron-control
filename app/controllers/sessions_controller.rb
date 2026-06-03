# Quick session-cookie login for the operator console. Authenticates an existing
# User (has_secure_password) by email + password and stores their id in the
# session. No registration, password reset, or rate limiting: this is an internal
# gate, not a public auth system.
class SessionsController < ApplicationController
  layout "auth"

  def new
    redirect_to console_principals_path if current_user
  end

  def create
    user = User.find_by(email: params[:email].to_s.strip.downcase)
    if user&.authenticate(params[:password])
      reset_session
      session[:user_id] = user.id
      redirect_to console_principals_path, notice: "Signed in as #{user.email}."
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end
end
