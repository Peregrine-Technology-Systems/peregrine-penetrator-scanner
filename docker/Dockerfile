# Scanner baked image — staging and production only
# Built on staging merge, tagged as production on main merge
# Development uses clone mode (no Docker build)
ARG DOCKER_REGISTRY=us-central1-docker.pkg.dev/peregrine-pentest-dev/pentest
FROM ${DOCKER_REGISTRY}/scanner-base:latest

ENV APP_ENV=production
ENV RUBY_YJIT_ENABLE=1

# Bake the build commit into the image so the running scan can prove which bits
# it executed (smoke-test asserts envelope scanner_commit == deployed commit).
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment true && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4

COPY . .

RUN mkdir -p tmp/scans tmp/reports storage/reports log custom_templates/nuclei

CMD ["bundle", "exec", "bin/scan"]
