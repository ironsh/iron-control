class Principal < ApplicationRecord
  oid_prefix "prn"

  attr_readonly :namespace, :foreign_id

  has_many :grants, dependent: :destroy
  has_many :proxies, dependent: :destroy

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)" }
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace },
            format: { with: URL_SAFE_FORMAT, message: "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)" }
end
