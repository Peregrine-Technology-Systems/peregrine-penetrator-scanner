#!/usr/bin/env bash
# Authenticate bundler's clone of the private `peregrine_bus` git-dependency
# (scanner#1009). Bundler clones git-deps over HTTPS in a child process that does
# NOT inherit the Woodpecker clone step's credentials, so the clone fails with
# "could not read Username for 'https://github.com'". Rewriting github.com HTTPS to
# carry the CI gh_token lets the private git-dep resolve. No private source is
# committed (vendoring into this PUBLIC repo would leak peregrine-bus).
#
# Source this before `bundle install`. No-op when GH_TOKEN is absent.
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global \
    url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi
