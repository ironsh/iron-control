class AddNameToPrincipalsAndForeignIdToStaticSecretRefs < ActiveRecord::Migration[8.1]
  def change
    add_column :principals, :name, :string
    change_column_null :principals, :namespace, true
    change_column_null :principals, :foreign_id, true

    add_column :static_secret_refs, :foreign_id, :string
    change_column_null :static_secret_refs, :namespace, true
    change_column_null :static_secret_refs, :name, true

    remove_index :static_secret_refs, name: "index_static_secret_refs_on_namespace_and_name"
    add_index :static_secret_refs, [ :namespace, :foreign_id ], unique: true
  end
end
