class AddCreatedByToApiResources < ActiveRecord::Migration[8.1]
  TABLES = %i[grants principals static_secret_refs].freeze

  def change
    TABLES.each do |table|
      add_reference table, :created_by, null: false, foreign_key: { to_table: :api_keys }
    end
  end
end
