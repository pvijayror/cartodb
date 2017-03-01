$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "carto_gears_api/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "carto_gears_api"
  s.version     = CartoGearsApi::VERSION
  s.authors     = ["CARTO"]
  s.email       = ["support@carto.com"]
  s.homepage    = "https://carto.com"
  s.summary     = "CARTO Gears API"
  s.description = "CARTO Gears API"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 3.2.22"
  s.add_dependency 'values', '1.8.0'

  s.add_development_dependency "rspec-rails", '2.12.0'
  s.add_development_dependency "rack-test", '0.6.3'
  s.add_development_dependency "mocha", '1.1.0'
  s.add_development_dependency "byebug"
end
