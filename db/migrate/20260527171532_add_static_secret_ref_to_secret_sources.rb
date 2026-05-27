class AddStaticSecretRefToSecretSources < ActiveRecord::Migration[8.1]
  def change
    add_reference :secret_sources, :static_secret_ref, null: true, foreign_key: true, index: { unique: true }
  end
end
