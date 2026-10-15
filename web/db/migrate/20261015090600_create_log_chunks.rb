# frozen_string_literal: true

class CreateLogChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :log_chunks do |t|
      t.references :job_run, null: false, foreign_key: true
      t.integer :seq, null: false
      t.text :chunk, null: false

      t.timestamps
    end

    # Retry-safe upserts: (job_run_id, seq) is the idempotency key.
    add_index :log_chunks, %i[job_run_id seq], unique: true, name: "index_log_chunks_on_job_run_id_and_seq"
  end
end
