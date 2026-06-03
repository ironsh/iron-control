Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Operator console (server-rendered HTML UI).
  root "console#principals"
  get "console/principals", to: "console#principals", as: :console_principals
  get "console/principals/:id", to: "console#principal", as: :console_principal
  get "console/secrets", to: "console#secrets", as: :console_secrets

  namespace :api do
    namespace :v1 do
      # Each secret type is addressable by opaque oid (member routes) or by an
      # explicit namespace + foreign_id via the namespaced lookup route.
      resources :static_secrets, only: %i[index show create update] do
        collection { get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup }
      end
      resources :gcp_auth_secrets, only: %i[index show create update] do
        collection { get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup }
      end
      resources :oauth_token_secrets, only: %i[index show create update] do
        collection { get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup }
      end
      resources :pg_dsn_secrets, only: %i[index show create update] do
        collection { get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup }
      end
      resources :hmac_secrets, only: %i[index show create update] do
        collection { get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup }
      end
      resources :roles, only: %i[index show create update destroy] do
        collection do
          get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup
        end
        # Grants whose grantee is this role. :role_id is the role's oid.
        resources :grants, only: %i[index], controller: :grantee_grants
      end
      resources :principals, only: %i[index show create update] do
        collection do
          get "lookup/:namespace/:foreign_id", action: :lookup, as: :lookup
          get "lookup/:namespace/:foreign_id/effective_config",
              action: :effective_config, as: :lookup_effective_config
        end
        member do
          get "effective_config"
        end
        # Role assignments for a principal. :id is the role's oid.
        resources :roles, only: %i[index create destroy], controller: :principal_roles
        # Grants whose grantee is this principal. :principal_id is the principal's oid.
        resources :grants, only: %i[index], controller: :grantee_grants
      end
      resources :grants, only: %i[show create destroy]
      resources :api_keys, only: %i[index show create destroy]
      resources :proxies, only: %i[index show create update destroy]

      # Called by iron-proxy instances (proxy bearer auth, not ApiKey auth).
      post "proxy/sync", to: "proxy_sync#create"
    end
  end

  # Render a JSON 404 for any unmatched route instead of the static error page.
  match "*path", to: "errors#not_found", via: :all
end
