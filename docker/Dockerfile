# Stage 1: Security tools layer
FROM --platform=linux/amd64 ubuntu:22.04 AS tools

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl git unzip python3 python3-pip ca-certificates \
    default-jre-headless perl libnet-ssleay-perl \
    && rm -rf /var/lib/apt/lists/*

# OWASP ZAP
RUN mkdir -p /opt/zap && \
    wget -q "https://github.com/zaproxy/zaproxy/releases/download/v2.15.0/ZAP_2.15.0_Linux.tar.gz" -O /tmp/zap.tar.gz && \
    tar -xzf /tmp/zap.tar.gz -C /opt/zap --strip-components=1 && \
    rm /tmp/zap.tar.gz && \
    ln -s /opt/zap/zap.sh /usr/local/bin/zap.sh

# ZAP Python scripts
RUN pip3 install --no-cache-dir --break-system-packages zaproxy python-owasp-zap-v2.4 && \
    wget -q https://raw.githubusercontent.com/zaproxy/zaproxy/main/docker/zap-baseline.py -O /usr/local/bin/zap-baseline.py && \
    wget -q https://raw.githubusercontent.com/zaproxy/zaproxy/main/docker/zap-full-scan.py -O /usr/local/bin/zap-full-scan.py && \
    wget -q https://raw.githubusercontent.com/zaproxy/zaproxy/main/docker/zap-api-scan.py -O /usr/local/bin/zap-api-scan.py && \
    chmod +x /usr/local/bin/zap-*.py

# Nuclei
RUN NUCLEI_VERSION=3.2.4 && \
    wget -q "https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/nuclei_${NUCLEI_VERSION}_linux_amd64.zip" -O /tmp/nuclei.zip && \
    unzip -o /tmp/nuclei.zip -d /usr/local/bin/ && \
    rm /tmp/nuclei.zip && \
    nuclei -update-templates || true

# sqlmap
RUN git clone --depth 1 https://github.com/sqlmapproject/sqlmap.git /opt/sqlmap && \
    ln -s /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap

# ffuf
RUN FFUF_VERSION=2.1.0 && \
    wget -q "https://github.com/ffuf/ffuf/releases/download/v${FFUF_VERSION}/ffuf_${FFUF_VERSION}_linux_amd64.tar.gz" -O /tmp/ffuf.tar.gz && \
    tar -xzf /tmp/ffuf.tar.gz -C /usr/local/bin/ ffuf && \
    rm /tmp/ffuf.tar.gz

# Nikto
RUN git clone --depth 1 https://github.com/sullo/nikto.git /opt/nikto && \
    ln -s /opt/nikto/program/nikto.pl /usr/local/bin/nikto

# SecLists (common wordlists only - keeps image smaller)
RUN git clone --depth 1 https://github.com/danielmiessler/SecLists.git /tmp/seclists && \
    mkdir -p /usr/share/seclists/Discovery/Web-Content && \
    cp /tmp/seclists/Discovery/Web-Content/common.txt /usr/share/seclists/Discovery/Web-Content/ && \
    cp /tmp/seclists/Discovery/Web-Content/directory-list-2.3-medium.txt /usr/share/seclists/Discovery/Web-Content/ && \
    rm -rf /tmp/seclists

# Stage 2: Rails application
FROM --platform=linux/amd64 ruby:3.2.2-slim AS app

ENV DEBIAN_FRONTEND=noninteractive
ENV RAILS_ENV=production
ENV RAILS_LOG_TO_STDOUT=true
ENV RUBY_YJIT_ENABLE=1
ENV SECRET_KEY_BASE=placeholder_for_build_only

# System deps for Rails + Chromium for PDF generation
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libsqlite3-dev \
    default-jre-headless python3 perl libnet-ssleay-perl \
    chromium \
    curl wget git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy security tools from tools stage
COPY --from=tools /opt/zap /opt/zap
COPY --from=tools /usr/local/bin/zap* /usr/local/bin/
COPY --from=tools /usr/local/bin/nuclei /usr/local/bin/
COPY --from=tools /opt/sqlmap /opt/sqlmap
COPY --from=tools /usr/local/bin/sqlmap /usr/local/bin/
COPY --from=tools /usr/local/bin/ffuf /usr/local/bin/
COPY --from=tools /opt/nikto /opt/nikto
COPY --from=tools /usr/local/bin/nikto /usr/local/bin/
COPY --from=tools /usr/share/seclists /usr/share/seclists
COPY --from=tools /root/.local/share/nuclei-templates /root/.local/share/nuclei-templates

# Set up app directory
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

# Set up database
RUN bundle exec rails db:create db:migrate

# Grover/Puppeteer config for Chromium
ENV GROVER_NO_SANDBOX=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

ENTRYPOINT ["bundle", "exec"]
CMD ["rake", "scan:run"]
