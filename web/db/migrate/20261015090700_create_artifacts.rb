# frozen_string_literal: true

class CreateArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :artifacts do |t|
      t.references :job_run, null: false, foreign_key: true
      t.string :path, null: false
      t.string :destination
      t.bigint :size
      t.string :storage_key

      t.timestamps
    end
  end
end
