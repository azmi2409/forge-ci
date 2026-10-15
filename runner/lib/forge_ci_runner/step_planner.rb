# frozen_string_literal: true

module ForgeCIRunner
  # Pure step-planning logic: ordering, display names, and `when`
  # evaluation. No Docker, no network — fully unit-testable.
  #
  # Step names follow the server convention (see PipelineIntake):
  #   step["name"] || step["type"]
  # so the names reported in step_results match the stored StepRuns.
  class StepPlanner
    Entry = Struct.new(:index, :name, :step, keyword_init: true)

    # Ordered plan entries for the job's steps.
    def self.plan(steps)
      Array(steps).each_with_index.map do |step, i|
        Entry.new(index: i, name: display_name(step), step: step)
      end
    end

    def self.display_name(step)
      (step["name"] || step["type"] || "step").to_s
    end

    # Whether the step should execute given whether any earlier step
    # in this job has already failed. Only `run` steps carry a runtime
    # `when` in the IR (compile-time conditionals are resolved by the
    # compiler); any other step type defaults to on_success semantics.
    def self.runnable?(step, failed_already)
      case step["when"].to_s
      when "", "on_success" then !failed_already
      when "on_fail" then failed_already
      when "always" then true
      else !failed_already
      end
    end
  end
end
