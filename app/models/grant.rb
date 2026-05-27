class Grant < ApplicationRecord
  oid_prefix "grant"

  attr_readonly :principal_id, :static_secret_ref_id

  belongs_to :principal
  belongs_to :static_secret_ref
  belongs_to :created_by, -> { unscoped }, class_name: "ApiKey"
end
