class AddStaticSecretRefToRequestRules < ActiveRecord::Migration[8.1]
  def change
    add_reference :request_rules, :static_secret_ref, null: true, foreign_key: true
  end
end
