# frozen_string_literal: true

Rails.application.routes.draw do
  # --- Web UI (HTTP basic auth, see ApplicationController) -------------------
  root "projects#index"

  resources :projects, only: %i[index] do
    resources :pipelines, only: %i[show]
  end
  resources :job_runs, only: %i[show]

  # --- API v1 ----------------------------------------------------------------
  namespace :api do
    namespace :v1 do
      # Pipeline intake — the seam the GitHub App (component 3) calls.
      resources :projects, only: [] do
        resources :pipelines, only: %i[create]
      end

      # Runner polling API (Bearer-token auth via RunnerToken).
      namespace :runner do
        resources :jobs, only: [] do
          collection do
            post :claim
          end
          member do
            post :heartbeat
            post :start
            post :complete
          end
        end
      end

      # Log streaming (Bearer-token auth; only the owning token).
      resources :jobs, only: [] do
        member do
          post :log_chunks, action: :create_log_chunk, controller: "jobs"
          get :logs, controller: "jobs"
        end
      end
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions
  get "up" => "rails/health#show", as: :rails_health_check
end
