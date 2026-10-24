# frozen_string_literal: true

Rails.application.routes.draw do
  # --- OAuth provider for the CLI (config/initializers/doorkeeper.rb) --------
  # /oauth/authorize | /oauth/token | /oauth/revoke. The applications
  # management UI is also mounted but answers 403 to everyone: no
  # admin_authenticator is configured (the CLI client is seeded, see
  # CliOauthApp).
  use_doorkeeper

  # --- Public landing page (no auth) -----------------------------------------
  root "landing#show"
  get "/dashboard", to: redirect("/projects")

  # --- Runner install (public: the token comes from the admin's command) ------
  get "/install-runner", to: "runner_install#script", as: :install_runner
  get "/runner.tar.gz", to: "runner_install#tarball", as: :runner_tarball, format: false

  # --- Sessions / accounts -------------------------------------------------
  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout
  resource :account, only: %i[show update] do
    post :sign_out_everywhere
  end
  resources :users, except: %i[show]
  resource :settings, only: %i[show] do
    post :github
    get "github/callback", action: :github_callback, as: :github_callback
  end

  # --- Web UI (cookie-session login, see ApplicationController) ------------

  resources :projects, only: %i[index show] do
    resources :pipelines, only: %i[show] do
      member do
        post :cancel
        post :rerun
      end
    end
    resources :variables, only: %i[create destroy], controller: "project_variables"
  end
  resources :job_runs, only: %i[show]

  # --- API v1 ----------------------------------------------------------------
  namespace :api do
    namespace :v1 do
      # Who the presented token authenticates as (`forge-ci login` verifies
      # with this and prints it).
      get "me", to: "me#show"

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

      # Queue depth per resource class, for runner autoscalers (admin-token authed).
      get "queue", to: "queue#show"

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
            post :release
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
