# frozen_string_literal: true

class EncryptJobRunContextEnvironment < ActiveRecord::Migration[8.1]
  def up
    add_column :job_runs, :encrypted_context_environment, :text

    # Independent of JobRun: its current schema already expects the encrypted column.
    snapshots = Class.new(ActiveRecord::Base) do
      self.table_name = "job_runs"
      serialize :encrypted_context_environment, coder: JSON
      encrypts :encrypted_context_environment
    end
    snapshots.reset_column_information

    snapshots.in_batches(of: 500) do |batch|
      batch.pluck(:id, :context_environment).each do |id, raw|
        begin
          environment = raw.present? ? JSON.parse(raw) : nil
        rescue JSON::ParserError
          raise ActiveRecord::MigrationError, "Invalid context snapshot for job #{id}", cause: nil
        end
        unless environment.nil? || environment.is_a?(Hash)
          raise ActiveRecord::MigrationError, "Invalid context snapshot for job #{id}"
        end

        # Only encrypted data reaches SQL writes; no callbacks, validation, or secret output.
        snapshots.find(id).update_columns(encrypted_context_environment: environment)
      end
    end

    remove_column :job_runs, :context_environment, :text
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Context snapshots must not be restored to plaintext"
  end
end
