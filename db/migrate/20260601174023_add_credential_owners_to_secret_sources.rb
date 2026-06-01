class AddCredentialOwnersToSecretSources < ActiveRecord::Migration[8.1]
  def change
    # A SecretSource hangs off exactly one owner. static_secret already exists;
    # gcp_auth_secret is the (1:1) keyfile, oauth_token_secret holds an entry's
    # credential fields and token-endpoint headers (1:many, disambiguated by role).
    add_reference :secret_sources, :gcp_auth_secret, null: true, foreign_key: true, index: { unique: true }
    add_reference :secret_sources, :oauth_token_secret, null: true, foreign_key: true

    add_column :secret_sources, :role, :string
    add_column :secret_sources, :endpoint_header, :boolean, null: false, default: false

    # One source per (entry, role) — credential fields and endpoint headers alike.
    add_index :secret_sources, [ :oauth_token_secret_id, :role, :endpoint_header ],
              unique: true, name: "index_secret_sources_on_oauth_owner_and_role"
  end
end
