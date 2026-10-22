# frozen_string_literal: true

# A project's environment variables in the dashboard (admins only). Saving a
# name that already exists replaces its value.
class ProjectVariablesController < ApplicationController
  before_action :require_admin
  before_action :set_project

  def create
    name = params[:name].to_s.strip
    variable = @project.variables.find_or_initialize_by(name: name)
    replaced = variable.persisted?
    variable.value = params[:value].to_s

    if variable.save
      redirect_to project_path(@project, anchor: "variables"),
                  notice: "#{replaced ? 'Updated' : 'Added'} #{variable.name}. Jobs that haven't started yet get the new value."
    else
      redirect_to project_path(@project, anchor: "variables"),
                  alert: "#{name.presence || 'The variable'} wasn't saved: #{variable.errors.full_messages.to_sentence}."
    end
  end

  def destroy
    variable = @project.variables.find(params[:id])
    variable.destroy!
    redirect_to project_path(@project, anchor: "variables"), notice: "Deleted #{variable.name}."
  end

  private

  def set_project
    @project = Project.find(params[:project_id])
  end
end
