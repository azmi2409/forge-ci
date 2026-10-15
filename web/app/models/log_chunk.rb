# frozen_string_literal: true

class LogChunk < ApplicationRecord
  belongs_to :job_run

  validates :seq, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :chunk, presence: true
  validates :seq, uniqueness: { scope: :job_run_id }
end
