# frozen_string_literal: true

require "test_helper"

# Concurrent-claim race. NOT transactional: threads need committed rows on
# separate connections. Cleanup is scoped to the rows this test creates so
# parallel test processes are unaffected.
class RunnerClaimRaceTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @project = Project.create!(name: "race-project", max_concurrency: 4)
    rec_a, @raw_a = RunnerToken.generate!(name: "race-a", resource_class: "medium")
    rec_b, @raw_b = RunnerToken.generate!(name: "race-b", resource_class: "medium")
    @token_ids = [rec_a.id, rec_b.id]

    yaml = file_fixture("ci_config.yml").read
    ir, errors = ForgeCI::Compiler.compile(yaml)
    assert_empty errors
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "race", branch: "main", ir: JSON.parse(ir.to_json) }, as: :json
    assert_response :created
  end

  teardown do
    Project.where(id: @project.id).destroy_all
    RunnerToken.where(id: @token_ids).delete_all
  end

  test "two tokens racing for one job: exactly one wins" do
    results = {}
    threads = { a: @raw_a, b: @raw_b }.map do |key, raw|
      Thread.new do
        open_session do |sess|
          results[key] =
            begin
              sess.post "/api/v1/runner/jobs/claim", headers: bearer_headers(raw)
              sess.response.status
            rescue ActiveRecord::StatementInvalid, SQLite3::BusyException
              # SQLite: the loser can hit a write conflict instead of a clean
              # 422 — that is still "losing the race".
              :contention
            end
        end
      end
    end
    threads.each(&:join)

    assert_equal 1, results.values.count(200), "exactly one claim must win, got #{results.inspect}"
    assert results.values.all? { |s| [200, 422, :contention].include?(s) }, results.inspect
    assert_equal 1, JobRun.where(status: "claimed").count
  end
end
