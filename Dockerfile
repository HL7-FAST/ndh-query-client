# Build stage
FROM ruby:3.3.10-alpine AS builder

# Install build dependencies
RUN apk --no-cache add build-base nodejs libpq-dev yaml-dev

WORKDIR /ndh-query-client

# Install gems
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 20 --retry 5 && \
    bundle clean --force && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    find /usr/local/bundle/gems/ -name "*.c" -delete && \
    find /usr/local/bundle/gems/ -name "*.o" -delete

# Runtime stage
FROM ruby:3.3.10-alpine

# Install only runtime dependencies
RUN apk --no-cache add tzdata libpq yaml nodejs

WORKDIR /ndh-query-client

# Copy gems from builder
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Copy application
COPY . ./

# Make entrypoint script executable
RUN chmod +x docker-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
