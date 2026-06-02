class Grant < ApplicationRecord
  oid_prefix "grant"

  GRANTEE_ASSOCIATIONS = %i[principal role].freeze
  GRANTABLE_ASSOCIATIONS = %i[static_secret gcp_auth_secret oauth_token_secret pg_dsn_secret].freeze

  attr_readonly :principal_id, :role_id, :static_secret_id, :gcp_auth_secret_id,
                :oauth_token_secret_id, :pg_dsn_secret_id

  belongs_to :principal, optional: true
  belongs_to :role, optional: true
  belongs_to :static_secret, optional: true
  belongs_to :gcp_auth_secret, optional: true
  belongs_to :oauth_token_secret, optional: true
  belongs_to :pg_dsn_secret, optional: true
  belongs_to :created_by, class_name: "User"

  validate :exactly_one_grantee
  validate :exactly_one_grantable

  # The grantee this grant attaches the secret to: a principal or a role.
  def grantee
    GRANTEE_ASSOCIATIONS.filter_map { |assoc| send(assoc) }.first
  end

  # The granted credential, whichever type it is.
  def grantable
    GRANTABLE_ASSOCIATIONS.filter_map { |assoc| send(assoc) }.first
  end

  private

  def exactly_one_grantee
    set = GRANTEE_ASSOCIATIONS.count { |assoc| send(assoc).present? }
    return if set == 1
    errors.add(:base, "must reference exactly one of #{GRANTEE_ASSOCIATIONS.join(", ")}")
  end

  def exactly_one_grantable
    set = GRANTABLE_ASSOCIATIONS.count { |assoc| send(assoc).present? }
    return if set == 1
    errors.add(:base, "must reference exactly one of #{GRANTABLE_ASSOCIATIONS.join(", ")}")
  end
end
