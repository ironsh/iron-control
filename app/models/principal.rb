class Principal < ApplicationRecord
  oid_prefix "prn"

  attr_readonly :namespace, :foreign_id

  validates :namespace, presence: true
  validates :foreign_id, presence: true, uniqueness: { scope: :namespace }
end
