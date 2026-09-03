# frozen_string_literal: true

# Points the generated apps at the database in this repository's
# docker-compose.yml, so `rake test_app`, `rspec`, `rake development_app` and
# the development app's own `bin/rails` all work without configuring anything.
# Every value defers to the environment, so CI (and anyone with their own
# Postgres) can override it.
#
# This is loaded from the Gemfile rather than from the Rakefile or spec_helper.
# The Gemfile is the only file every one of those processes evaluates: the
# development app is generated inside `Bundler.with_original_env`, which
# ENV.replace()s the environment back to a snapshot taken before the Rakefile
# ran, and it then boots against its own copy of this Gemfile.
#
# 127.0.0.1 rather than localhost: Docker publishes the port on IPv4, while
# localhost can resolve to ::1 first.
ENV["DATABASE_HOST"] ||= "127.0.0.1"
ENV["DATABASE_PORT"] ||= "5433"
ENV["DATABASE_USERNAME"] ||= "decidim"
ENV["DATABASE_PASSWORD"] ||= "decidim"
