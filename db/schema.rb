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

ActiveRecord::Schema[7.1].define(version: 2026_03_18_000004) do
  create_table "findings", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "scan_id", limit: 36, null: false
    t.string "source_tool", null: false
    t.string "severity", default: "info", null: false
    t.string "title", null: false
    t.text "url"
    t.string "parameter"
    t.string "cwe_id"
    t.text "evidence", default: "{}"
    t.string "fingerprint", null: false
    t.boolean "duplicate", default: false
    t.string "cve_id"
    t.float "cvss_score"
    t.float "epss_score"
    t.boolean "kev_known_exploited", default: false
    t.text "ai_assessment"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fingerprint"], name: "index_findings_on_fingerprint"
    t.index ["scan_id"], name: "index_findings_on_scan_id"
  end

  create_table "reports", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "scan_id", limit: 36, null: false
    t.string "format", null: false
    t.string "gcs_path"
    t.text "signed_url"
    t.datetime "signed_url_expires_at"
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["scan_id"], name: "index_reports_on_scan_id"
  end

  create_table "scans", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "target_id", limit: 36, null: false
    t.string "profile", default: "standard", null: false
    t.string "status", default: "pending", null: false
    t.text "tool_statuses", default: "{}"
    t.text "summary", default: "{}"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["target_id"], name: "index_scans_on_target_id"
  end

  create_table "targets", id: { type: :string, limit: 36 }, force: :cascade do |t|
    t.string "name", null: false
    t.text "urls", default: "[]", null: false
    t.string "auth_type", default: "none"
    t.text "auth_config"
    t.text "scope_config"
    t.text "brand_config"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "findings", "scans"
  add_foreign_key "reports", "scans"
  add_foreign_key "scans", "targets"
end
