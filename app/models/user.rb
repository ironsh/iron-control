class User < ApplicationRecord
  oid_prefix "usr"

  has_secure_password

  has_many :api_keys, dependent: :destroy

  normalizes :email, with: ->(e) { e.strip.downcase }

  validates :email,
            presence: true,
            uniqueness: true,
            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 12 }, allow_nil: true
end
