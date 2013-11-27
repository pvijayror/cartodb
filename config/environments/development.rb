# coding: UTF-8

CartoDB::Application.configure do
  # Settings specified here will take precedence over those in config/application.rb

  # In the development environment your application's code is reloaded on
  # every request.  This slows down response time but is perfect for development
  # since you don't have to restart the webserver when you make code changes.
  config.cache_classes = false

  # Log error messages when you accidentally call methods on nil.
  config.whiny_nils = true

  # Show full error reports and disable caching
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false

  # Don't care if the mailer can't send
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.delivery_method = :test

  # Print deprecation notices to the Rails logger
  config.active_support.deprecation = :log

  # Only use best-standards-support built into browsers
  config.action_dispatch.best_standards_support = :builtin

  config.action_mailer.default_url_options = { :host => 'localhost:3000' }
  
  # Reverse proxy to the local node sql api server listening on port 8080
  # config.middleware.use Rack::ReverseProxy do
  #  reverse_proxy /api\/v1\/sql(.*)/, 'http://vizzuality.localhost.lan:8080/api/v1/sql$1'
  # end
  
  # Do not compress assets
  config.assets.compress = false
  
  # Expands the lines which load the assets
  config.assets.debug = true

  # Add non-conventional classes to autoload path
  config.autoload_paths += ["#{config.root}/app/models/visualization"]
  config.autoload_paths += ["#{config.root}/app/models/overlay"]
  config.autoload_paths += ["#{config.root}/app/models/layer"]
  config.autoload_paths += ["#{config.root}/app/models/layergroup"]
  config.autoload_paths += ["#{config.root}/app/models/map"]
  config.autoload_paths += ["#{config.root}/app/models/table"]
  config.autoload_paths += ["#{config.root}/app/models/user"]
  
  config.assets.initialize_on_precompile = true

  # config.action_controller.asset_host = Proc.new { Cartodb.config[:app_assets] ? Cartodb.config[:app_assets]['asset_host'] : nil }
end

