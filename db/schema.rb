# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_28_111433) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "name", null: false
    t.string "token_hash", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["deleted_at"], name: "index_api_keys_on_deleted_at"
    t.index ["token_hash"], name: "index_api_keys_on_token_hash", unique: true
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.bigint "principal_id", null: false
    t.bigint "static_secret_ref_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_grants_on_created_by_id"
    t.index ["principal_id"], name: "index_grants_on_principal_id"
    t.index ["static_secret_ref_id"], name: "index_grants_on_static_secret_ref_id"
  end

  create_table "principals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.string "foreign_id"
    t.jsonb "labels", default: {}, null: false
    t.string "name"
    t.string "namespace", default: "default", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_principals_on_created_by_id"
    t.index ["labels"], name: "index_principals_on_labels", using: :gin
    t.index ["namespace", "foreign_id"], name: "index_principals_on_namespace_and_foreign_id", unique: true
  end

  create_table "proxies", force: :cascade do |t|
    t.string "bearer_token_hash", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "principal_id", null: false
    t.datetime "updated_at", null: false
    t.index ["principal_id"], name: "index_proxies_on_principal_id"
  end

  create_table "request_rules", force: :cascade do |t|
    t.string "cidr"
    t.datetime "created_at", null: false
    t.string "host"
    t.jsonb "http_methods", default: [], null: false
    t.jsonb "paths", default: [], null: false
    t.integer "position", default: 0, null: false
    t.bigint "static_secret_ref_id"
    t.datetime "updated_at", null: false
    t.index ["host"], name: "index_request_rules_on_host"
    t.index ["position"], name: "index_request_rules_on_position"
    t.index ["static_secret_ref_id"], name: "index_request_rules_on_static_secret_ref_id"
  end

  create_table "secret_sources", force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "secret"
    t.string "source_type", null: false
    t.bigint "static_secret_ref_id"
    t.datetime "updated_at", null: false
    t.index ["source_type"], name: "index_secret_sources_on_source_type"
    t.index ["static_secret_ref_id"], name: "index_secret_sources_on_static_secret_ref_id", unique: true
  end

  create_table "static_secret_refs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.string "description"
    t.string "foreign_id"
    t.jsonb "inject_config"
    t.jsonb "labels", default: {}, null: false
    t.string "name"
    t.string "namespace", default: "default", null: false
    t.jsonb "replace_config"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_static_secret_refs_on_created_by_id"
    t.index ["labels"], name: "index_static_secret_refs_on_labels", using: :gin
    t.index ["namespace", "foreign_id"], name: "index_static_secret_refs_on_namespace_and_foreign_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "api_keys", "users"
  add_foreign_key "grants", "principals"
  add_foreign_key "grants", "static_secret_refs"
  add_foreign_key "grants", "users", column: "created_by_id"
  add_foreign_key "principals", "users", column: "created_by_id"
  add_foreign_key "proxies", "principals"
  add_foreign_key "request_rules", "static_secret_refs"
  add_foreign_key "secret_sources", "static_secret_refs"
  add_foreign_key "static_secret_refs", "users", column: "created_by_id"
end
