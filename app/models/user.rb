class User < ApplicationRecord
  oid_prefix "usr"

  # validations: false because SSO-only users have no password. The password
  # length rule below still applies to anyone who does set one (password login is
  # kept as a break-glass fallback).
  has_secure_password validations: false

  has_many :api_keys, dependent: :destroy
  has_many :user_identities, dependent: :destroy
  belongs_to :approved_by, class_name: "User", optional: true

  # pending: signed in via SSO but not yet approved -- cannot use the console.
  # active: approved operator. disabled: access revoked.
  enum :status, { pending: "pending", active: "active", disabled: "disabled" },
       default: :pending, validate: true

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :email,
            presence: true,
            uniqueness: true,
            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true

  # Marks a pending user active, recording who approved them and when.
  def approve!(by:)
    update!(status: :active, approved_at: Time.current, approved_by: by)
  end
end
