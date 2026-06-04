class AddBrokerCredentialToSecretSources < ActiveRecord::Migration[8.1]
  def change
    # A broker_credential owns its input sources (client_id, client_secret, and
    # token-endpoint headers), disambiguated by role like oauth_token. It is not
    # grantable and has no request rules, so no grants/request_rules FK.
    add_reference :secret_sources, :broker_credential, null: true, foreign_key: true

    # One source per (entry, role, kind), mirroring the oauth_token owner index.
    add_index :secret_sources, [ :broker_credential_id, :role, :role_kind ],
              unique: true, name: "index_secret_sources_on_broker_credential_owner_and_role"
  end
end
