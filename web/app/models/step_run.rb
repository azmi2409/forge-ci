# frozen_string_literal: true

class StepRun < ApplicationRecord
  belongs_to :job_run

  enum :status, { pending: 0, running: 1, success: 2, failed: 3, canceled: 4 }

  validates :name, presence: true, uniqueness: { scope: :job_run_id }
end
