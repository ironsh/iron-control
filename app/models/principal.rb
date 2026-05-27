class Principal < ApplicationRecord
  oid_prefix "prn"

  attr_readonly :namespace, :foreign_id

  has_many :grants, dependent: :destroy
  has_many :proxies, dependent: :destroy

  validates :namespace, presence: true
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace }
end
