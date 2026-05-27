class RequireNamespaceWithDefault < ActiveRecord::Migration[8.1]
  def up
    Principal.where(namespace: nil).update_all(namespace: "default")
    StaticSecretRef.where(namespace: nil).update_all(namespace: "default")

    change_column_default :principals, :namespace, "default"
    change_column_null :principals, :namespace, false

    change_column_default :static_secret_refs, :namespace, "default"
    change_column_null :static_secret_refs, :namespace, false
  end

  def down
    change_column_null :static_secret_refs, :namespace, true
    change_column_default :static_secret_refs, :namespace, nil

    change_column_null :principals, :namespace, true
    change_column_default :principals, :namespace, nil
  end
end
