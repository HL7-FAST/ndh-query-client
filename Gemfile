# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '3.3.10'

gem 'dartsass-rails', '~> 0.5'  # Use Dart Sass for stylesheets (replaces sass-rails)
gem 'httparty', '~> 0.22'       # use httparty for geocoder access
gem 'puma', '~> 7.1'            # Use Puma as the app server
gem 'rails', '~> 8.1.0'         # Latest Rails version
gem 'sprockets-rails', '~> 3.5' # Asset pipeline for Rails (for compatibility)
gem 'terser', '~> 1.2'          # Use Terser as compressor for JavaScript assets (replaces uglifier)

gem 'jbuilder', '~> 2.13'       # Build JSON APIs with ease

# gem 'redis', '~> 4.0'         # Use Redis adapter to run Action Cable in production
# gem 'bcrypt', '~> 3.1.7'      # Use ActiveModel has_secure_password
# gem 'mini_magick', '~> 4.8'   # Use ActiveStorage variant

gem 'bootsnap', '~> 1.18', require: false # Reduces boot times through caching; required in config/boot.rb

gem 'bootstrap', '~> 5.3'       # Integrates Bootstrap HTML, CSS, and JavaScript framework
gem 'fhir_client', '~> 6.0'     # Handles FHIR client requests
gem 'jquery-rails', '~> 4.6'    # Automate using jQuery with Rails
gem 'leaflet-awesome-markers-rails', '~> 2.0'
gem 'sassc', '~> 2.4'           # Sass compiler (required by bootstrap)
# Custom markers for Leaflet

gem 'dalli', '~> 3.2'           # Memcache client
gem 'geokit-rails', '~> 2.5'    # Provides geolocation-based searches
gem 'leaflet-rails', '~> 1.9'   # Handles Leaflet-based maps
gem 'sqlite3', '~> 2.4'         # Use SQLite for database

group :development, :test do
  gem 'debug', '~> 1.9', platforms: %i[mri mingw x64_mingw] # Ruby debugger (replaces byebug)
  gem 'rubocop', '~> 1.70' # Ruby linter
  gem 'rubocop-rails', '~> 2.27' # Rails-specific rubocop rules
  gem 'seed_dump', '~> 3.3'     # Seed data dumper
end

group :development do
  gem 'web-console', '~> 4.2'   # Access an interactive console on exception pages
  # gem 'capistrano-rails'      # Use Capistrano for deployment
end

group :test do
  gem 'capybara', '~> 3.40' # Adds support for Capybara system testing and selenium driver
  gem 'selenium-webdriver', '~> 4.27' # WebDriver JavaScript bindings from the Selenium project
end

gem 'tzinfo-data', platforms: %i[mingw mswin x64_mingw jruby] # Windows does not include zoneinfo files, so bundle the tzinfo-data gem

gem 'pry', '~> 0.14'
