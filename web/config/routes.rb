# frozen_string_literal: true

Rails.application.routes.draw do
  # --- Public landing page (no auth) -----------------------------------------
  root "landing#show"
  get "/dashboard", to: redirect("/projects")

  # --- Sessions / accounts -------------------------------------------------
  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout
  resource :account, only: %i[show update] do
    post :sign_out_everywhere
  end
  resources :users, except: %i[show]

  # --- Web UI (cookie-session login, see ApplicationController) ------------

  resources :projects, only: %i[index] do
    resources :pipelines, only: %i[show] do
      member { post :cancel }
    end
  end
  resources :job_runs, only: %i[show]

  # --- API v1 ----------------------------------------------------------------
  namespace :api do
    namespace :v1 do
      # Pipeline intake — the seam the GitHub App (component 3) calls.
      # Cache API (component 7) — scoped to the project; the Bearer token
      # must own a claimed/running job in that project.
      resources :projects, only: %i[index create] do
        resources :pipelines, only: %i[create]
        resources :contexts, only: %i[create]
        member do
          put :cache, to: "cache#upsert"
          get :cache, to: "cache#show"
        end
      end

      # Pipeline status / cancel (admin-token authed).
      resources :pipelines, only: %i[show] do
        member { post :cancel }
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

      # Log streaming (component 6). Chunk ingest is Bearer-token authed to the
      # owning token; logs/stream additionally accepts the UI basic-auth
      # credentials so the job page can tail without a runner token.
      resources :jobs, only: [] do
        member do
          post :log_chunks, action: :create_log_chunk, controller: "jobs"
          get :logs, controller: "jobs"
          get "logs/stream", to: "jobs#stream"
          post :artifacts, to: "artifacts#create"
        end
      end

      # Artifact downloads (component 7): redirect to a fresh signed URL.
      resources :artifacts, only: [] do
        member do
          get :download, to: "artifacts#download"
        end
      end

      # Contexts (component 8): secret rotation is admin-token authed.
      resources :contexts, only: [] do
        member do
          post :rotate, to: "contexts#rotate"
        end
      end

      # GitHub App webhooks (HMAC-verified; see Api::V1::Github::WebhooksController).
      namespace :github do
        post "webhooks", to: "webhooks#create"
      end
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions
  get "up" => "rails/health#show", as: :rails_health_check
end
