# frozen_string_literal: true

class ProjectsController < ApplicationController
  def index
    @projects = Project.order(:name)
  end
end
