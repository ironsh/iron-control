class Principal < ApplicationRecord
  oid_prefix "prn"

  include ForeignIdCollisionGuard

  attr_readonly :namespace, :foreign_id

  has_many :grants, dependent: :destroy
  # Proxies outlive their principal: deleting a principal unassigns its proxies
  # rather than destroying them, leaving them ready for reassignment.
  has_many :proxies, dependent: :nullify
  has_many :principal_roles, dependent: :destroy
  has_many :roles, through: :principal_roles
  belongs_to :created_by, class_name: "User"

  URL_SAFE_FORMAT = /\A[A-Za-z0-9\-._~]+\z/
  URL_SAFE_MESSAGE = "must contain only URL-safe characters (A-Z, a-z, 0-9, -, ., _, ~)"

  validates :namespace, presence: true, format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }
  validates :foreign_id, uniqueness: { scope: :namespace, allow_nil: true },
            format: { with: URL_SAFE_FORMAT, message: URL_SAFE_MESSAGE }, allow_nil: true

  # Every grant this principal resolves to: its own direct grants plus the
  # grants of every role it is assigned. Secrets reachable through more than one
  # path collapse naturally because callers select distinct secret rows.
  def effective_grants
    Grant.where(principal_id: id).or(Grant.where(role_id: role_ids))
  end
end
