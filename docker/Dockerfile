# Scanner app image — gems + application code
# Built on every push to development
# Inherits security tools and runtime from scanner-base
ARG DOCKER_REGISTRY=us-central1-docker.pkg.dev/peregrine-pentest-dev/pentest
FROM ${DOCKER_REGISTRY}/scanner-base:latest

ENV APP_ENV=production
ENV RUBY_YJIT_ENABLE=1

WORKDIR /app

# Install gems
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment true && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p tmp/scans tmp/reports storage/reports log custom_templates/nuclei

# Database is created at boot (Penetrator.boot! runs migrations)
CMD ["bin/scan"]
