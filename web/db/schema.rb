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

ActiveRecord::Schema[8.1].define(version: 2026_10_22_120000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.integer "record_id", null: false
    t.integer "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.integer "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "artifacts", force: :cascade do |t|
    t.integer "job_run_id", null: false
    t.string "path", null: false
    t.string "destination"
    t.bigint "size"
    t.string "storage_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_run_id"], name: "index_artifacts_on_job_run_id"
  end

  create_table "cache_entries", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "key", null: false
    t.string "storage_key"
    t.bigint "size"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "key"], name: "index_cache_entries_on_project_id_and_key", unique: true
    t.index ["project_id"], name: "index_cache_entries_on_project_id"
  end

  create_table "contexts", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "name", null: false
    t.text "encrypted_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "name"], name: "index_contexts_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_contexts_on_project_id"
  end

  create_table "github_installations", force: :cascade do |t|
    t.bigint "installation_id", null: false
    t.string "account_login", null: false
    t.string "account_type", default: "Organization", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["installation_id"], name: "index_github_installations_on_installation_id", unique: true
  end

  create_table "github_repositories", force: :cascade do |t|
    t.integer "github_installation_id", null: false
    t.integer "project_id", null: false
    t.string "full_name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["full_name"], name: "index_github_repositories_on_full_name", unique: true
    t.index ["github_installation_id"], name: "index_github_repositories_on_github_installation_id"
    t.index ["project_id"], name: "index_github_repositories_on_project_id"
  end

  create_table "job_runs", force: :cascade do |t|
    t.integer "workflow_run_id", null: false
    t.string "name", null: false
    t.text "executor"
    t.text "steps"
    t.string "working_directory"
    t.text "requires"
    t.string "resource_class"
    t.text "context_environment"
    t.string "concurrency_key"
    t.integer "status", default: 0, null: false
    t.string "claimed_by"
    t.datetime "claimed_at"
    t.datetime "heartbeat_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "parallelism", default: 1, null: false
    t.integer "node_index", default: 0, null: false
    t.index ["resource_class"], name: "index_job_runs_on_resource_class"
    t.index ["status"], name: "index_job_runs_on_status"
    t.index ["workflow_run_id", "name", "node_index"], name: "index_job_runs_on_workflow_run_id_and_name_and_node_index", unique: true
    t.index ["workflow_run_id"], name: "index_job_runs_on_workflow_run_id"
  end

  create_table "log_chunks", force: :cascade do |t|
    t.integer "job_run_id", null: false
    t.integer "seq", null: false
    t.text "chunk", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_run_id", "seq"], name: "index_log_chunks_on_job_run_id_and_seq", unique: true
    t.index ["job_run_id"], name: "index_log_chunks_on_job_run_id"
  end

  create_table "pipelines", force: :cascade do |t|
    t.integer "project_id", null: false
    t.string "sha", null: false
    t.string "branch", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "forked", default: false, null: false
    t.integer "pipeline_number"
    t.integer "github_repository_id"
    t.index ["github_repository_id"], name: "index_pipelines_on_github_repository_id"
    t.index ["project_id", "created_at"], name: "index_pipelines_on_project_id_and_created_at"
    t.index ["project_id", "pipeline_number"], name: "index_pipelines_on_project_id_and_pipeline_number", unique: true
    t.index ["project_id"], name: "index_pipelines_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.string "name", null: false
    t.string "repo_url"
    t.string "default_branch", default: "main", null: false
    t.integer "max_concurrency", default: 4, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "runner_tokens", force: :cascade do |t|
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "resource_class"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_runner_tokens_on_name", unique: true
    t.index ["token_digest"], name: "index_runner_tokens_on_token_digest", unique: true
  end

  create_table "step_runs", force: :cascade do |t|
    t.integer "job_run_id", null: false
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.integer "exit_code"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_run_id", "name"], name: "index_step_runs_on_job_run_id_and_name", unique: true
    t.index ["job_run_id"], name: "index_step_runs_on_job_run_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "username", null: false
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.string "session_nonce", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_until"
    t.datetime "last_login_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  create_table "workflow_runs", force: :cascade do |t|
    t.integer "pipeline_id", null: false
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_id", "name"], name: "index_workflow_runs_on_pipeline_id_and_name", unique: true
    t.index ["pipeline_id"], name: "index_workflow_runs_on_pipeline_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "artifacts", "job_runs"
  add_foreign_key "cache_entries", "projects"
  add_foreign_key "contexts", "projects"
  add_foreign_key "github_repositories", "github_installations"
  add_foreign_key "github_repositories", "projects"
  add_foreign_key "job_runs", "workflow_runs"
  add_foreign_key "log_chunks", "job_runs"
  add_foreign_key "pipelines", "github_repositories"
  add_foreign_key "pipelines", "projects"
  add_foreign_key "step_runs", "job_runs"
  add_foreign_key "workflow_runs", "pipelines"
end
