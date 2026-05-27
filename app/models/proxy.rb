class Proxy < ApplicationRecord
  oid_prefix "prx"

  belongs_to :principal

  validates :name, presence: true
  validates :bearer_token_hash, presence: true
end
