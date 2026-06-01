class Grant < ApplicationRecord
  oid_prefix "grant"

  attr_readonly :principal_id, :static_secret_id

  belongs_to :principal
  belongs_to :static_secret
  belongs_to :created_by, class_name: "User"
end
