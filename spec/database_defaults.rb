# frozen_string_literal: true

# Points the generated test app at the database in this repository's
# docker-compose.yml, so `rake test_app` and `rspec` work without configuring
# anything. Every value defers to the environment, so CI (and anyone with their
# own Postgres) can override it.
ENV["DATABASE_HOST"] ||= "localhost"
ENV["DATABASE_PORT"] ||= "5433"
ENV["DATABASE_USERNAME"] ||= "decidim"
ENV["DATABASE_PASSWORD"] ||= "decidim"
