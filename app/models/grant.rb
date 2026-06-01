class Grant < ApplicationRecord
  oid_prefix "grant"

  GRANTABLE_ASSOCIATIONS = %i[static_secret gcp_auth_secret oauth_token_secret].freeze

  attr_readonly :principal_id, :static_secret_id, :gcp_auth_secret_id, :oauth_token_secret_id

  belongs_to :principal
  belongs_to :static_secret, optional: true
  belongs_to :gcp_auth_secret, optional: true
  belongs_to :oauth_token_secret, optional: true
  belongs_to :created_by, class_name: "User"

  validate :exactly_one_grantable

  # The granted credential, whichever type it is.
  def grantable
    GRANTABLE_ASSOCIATIONS.filter_map { |assoc| send(assoc) }.first
  end

  private

  def exactly_one_grantable
    set = GRANTABLE_ASSOCIATIONS.count { |assoc| send(assoc).present? }
    return if set == 1
    errors.add(:base, "must reference exactly one of #{GRANTABLE_ASSOCIATIONS.join(", ")}")
  end
end
