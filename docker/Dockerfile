# Scanner app image — application code only
# Built only when this Dockerfile changes
# Inherits security tools and runtime from scanner-base
# Gems installed at VM boot via bundle install (not baked into image)
ARG DOCKER_REGISTRY=us-central1-docker.pkg.dev/peregrine-pentest-dev/pentest
FROM ${DOCKER_REGISTRY}/scanner-base:latest

ENV APP_ENV=production
ENV RUBY_YJIT_ENABLE=1

WORKDIR /app

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p tmp/scans tmp/reports storage/reports log custom_templates/nuclei

# Gems installed at boot: bundle install --deployment --without development test
CMD ["bin/scan"]
