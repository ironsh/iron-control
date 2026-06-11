class CreateOauthApps < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_apps do |t|
      # Identity (same shape as broker_credentials).
      t.string :namespace, null: false, default: "default"
      t.string :foreign_id
      t.string :name
      t.string :description
      t.jsonb :labels, null: false, default: {}

      # Which provider strategy drives this app's consent flows ("google").
      t.string :provider, null: false

      # OAuth client. client_id is not secret; client_secret is encrypted at the
      # model layer.
      t.string :client_id, null: false
      t.text :client_secret

      # Scopes the start endpoint may request. The flow's `scopes` param must be a
      # subset; when omitted, all allowed scopes are requested.
      t.jsonb :allowed_scopes, null: false, default: []

      # Allowlist of return-URL prefixes the callback may redirect to. The first
      # entry is the default when the flow omits return_to.
      t.jsonb :allowed_return_urls, null: false, default: []

      # Namespace for broker credentials minted by this app's flows.
      t.string :credential_namespace, null: false, default: "default"

      # Kill switch: a disabled app rejects new start/callback flows but existing
      # credentials keep refreshing.
      t.boolean :enabled, null: false, default: true

      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :oauth_apps, [ :namespace, :foreign_id ], unique: true
    add_index :oauth_apps, :labels, using: :gin
  end
end
