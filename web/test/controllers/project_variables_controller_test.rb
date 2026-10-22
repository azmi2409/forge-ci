# frozen_string_literal: true

require "test_helper"

class ProjectVariablesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "acme/web", max_concurrency: 2)
  end

  test "admins add, replace and delete variables; values are never shown again" do
    sign_in_as_admin
    post "/projects/#{@project.id}/variables", params: { name: "DEPLOY_TOKEN", value: "tok-abcdefgh-9876" }
    assert_redirected_to "/projects/#{@project.id}#variables"
    assert_equal "tok-abcdefgh-9876", @project.variables.find_by(name: "DEPLOY_TOKEN").value

    post "/projects/#{@project.id}/variables", params: { name: " DEPLOY_TOKEN ", value: "tok-new-value-5555" }
    assert_equal 1, @project.variables.count
    assert_match "Updated DEPLOY_TOKEN", flash[:notice]

    get "/projects/#{@project.id}"
    assert_response :ok
    assert_select "#variables td.mono", text: "DEPLOY_TOKEN"
    assert_match "••••5555", response.body
    assert_no_match "tok-new-value", response.body

    delete "/projects/#{@project.id}/variables/#{@project.variables.first.id}"
    assert_equal 0, @project.variables.count
  end

  test "invalid names are refused without echoing the value" do
    sign_in_as_admin
    post "/projects/#{@project.id}/variables", params: { name: "bad name", value: "hunter2-secret" }
    assert_equal 0, @project.variables.count
    assert_match "wasn't saved", flash[:alert]
    assert_no_match "hunter2", flash[:alert]
  end

  test "members see names but can't change them" do
    @project.variables.create!(name: "VISIBLE", value: "member-cannot-see-1234")
    sign_in_as("member", role: :member)
    get "/projects/#{@project.id}"
    assert_response :ok
    assert_match "VISIBLE", response.body
    assert_select "form[action='/projects/#{@project.id}/variables']", count: 0

    post "/projects/#{@project.id}/variables", params: { name: "NOPE", value: "x" }
    assert_nil @project.variables.find_by(name: "NOPE")
  end
end
