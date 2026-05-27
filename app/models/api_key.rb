class ApiKey < ApplicationRecord
  oid_prefix "ak"

  TOKEN_PREFIX = "iak_".freeze

  attr_readonly :user_id, :token_hash
  attr_accessor :token

  belongs_to :user

  validates :name, presence: true
  validates :token_hash, presence: true, uniqueness: true

  before_validation :issue_token, on: :create

  def self.find_by_token(plaintext)
    return nil if plaintext.blank?
    find_by(token_hash: hash_token(plaintext))
  end

  def self.hash_token(plaintext)
    Digest::SHA256.hexdigest(plaintext)
  end

  private

  def issue_token
    return if token_hash.present?
    self.token = "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
    self.token_hash = self.class.hash_token(token)
  end
end
