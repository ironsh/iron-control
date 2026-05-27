class CreateStaticSecretRefs < ActiveRecord::Migration[8.1]
  def change
    create_table :static_secret_refs do |t|
      t.string :namespace, null: false
      t.string :name, null: false
      t.string :description
      t.jsonb :labels, null: false, default: {}
      t.jsonb :inject_config
      t.jsonb :replace_config

      t.timestamps
    end

    add_index :static_secret_refs, [ :namespace, :name ], unique: true
    add_index :static_secret_refs, :labels, using: :gin
  end
end
