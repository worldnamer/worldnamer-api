Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Creates the Warden/Devise mapping for User without adding any Devise routes (we write our own below).
  devise_for :users, skip: :all, failure_app: "Auth::FailureApp"

  # /up is the Rails 8 convention for load balancer and uptime probes. It is served by our health
  # controller instead of the built-in Rails::HealthController, so both paths behave the same.
  get "up", to: "api/v1/health#show"

  namespace :api do
    namespace :v1 do
      get "health", to: "health#show"
      post "session", to: "sessions#create"
      post "session/refresh", to: "sessions#refresh"
      delete "session", to: "sessions#destroy"
      get "me", to: "me#show"
      resource :task_list_order, only: :update
      # Singular: each user has at most one. GoogleCalendarConnectionsController#show.
      resource :google_calendar_connection, only: :show do
        # GoogleCalendarConnections::AuthorizationsController#create
        resource :authorization, only: :create, module: :google_calendar_connections
        # GoogleCalendarConnections::CallbacksController#show. Google redirects here; no bearer token.
        resource :callback, only: :show, module: :google_calendar_connections
        # GoogleCalendarConnections::EventsController#index. The caller's own events only; no ids in the path.
        resources :events, only: :index, module: :google_calendar_connections
      end
      resources :task_lists, only: %i[index create update destroy] do
        resources :tasks, only: %i[index create update destroy]
        # DoneTasksController#destroy. Singular: no id in the path, it means this list's done tasks.
        resource :done_tasks, only: :destroy
      end
      # RecipesController. The caller's own recipes only.
      resources :recipes, only: %i[index show create]
      resources :habits, only: %i[index create destroy] do
        # /habits/:habit_id/completions/:date. param: :date names the segment :date instead of :id.
        resources :completions, only: %i[update destroy], param: :date
      end
    end
  end

  # An API has nothing to serve at "/". Defining a root route stops Rails from showing its
  # development-only welcome page there, and raising makes "/" a 404 like any other unknown path.
  root to: ->(env) { raise ActionController::RoutingError, "No route matches [#{env["REQUEST_METHOD"]}] \"/\"" }
end
