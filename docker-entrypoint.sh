#!/bin/sh
set -e

echo "Running database setup..."

# Create database if it doesn't exist
bundle exec rake db:create || true

# Run migrations
bundle exec rake db:migrate

# Seed zipcodes if needed
if [ -f "db/seed_zipcodes.rb" ]; then
  echo "Seeding zipcodes..."
  ruby db/seed_zipcodes.rb
fi

echo "Database setup complete!"

# Execute the main command
exec "$@"
