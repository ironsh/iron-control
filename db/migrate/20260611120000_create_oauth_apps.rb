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

      # Globally-unique URL name for the app's well-known consent links:
      # /oauth/<slug>/start and /oauth/<slug>/callback. Distinct from
      # namespace/foreign_id (which address the app in the API) so the public
      # link is a single short token a team member can recognize ("google").
      t.string :slug, null: false

      # OAuth client. client_id is not secret; client_secret is encrypted at the
      # model layer.
      t.string :client_id, null: false
      t.text :client_secret

      # Scopes the start endpoint requests. When the flow omits its optional
      # `scopes` param, all of these are requested.
      t.jsonb :allowed_scopes, null: false, default: []

      # Namespace for broker credentials minted by this app's flows.
      t.string :credential_namespace, null: false, default: "default"

      # Kill switch: a disabled app rejects new start/callback flows but existing
      # credentials keep refreshing.
      t.boolean :enabled, null: false, default: true

      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :oauth_apps, [ :namespace, :foreign_id ], unique: true
    add_index :oauth_apps, :slug, unique: true
    add_index :oauth_apps, :labels, using: :gin
  end
end
