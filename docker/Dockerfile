# Stage 0: Copy ZAP scan scripts from official image
FROM --platform=linux/amd64 ghcr.io/zaproxy/zaproxy:stable AS zap-source

# Stage 1: Security tools layer
FROM --platform=linux/amd64 ubuntu:22.04 AS tools

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl git unzip python3 python3-pip ca-certificates \
    default-jre-headless perl libnet-ssleay-perl \
    && rm -rf /var/lib/apt/lists/*

# OWASP ZAP - copy from official image
COPY --from=zap-source /zap /opt/zap
RUN ln -s /opt/zap/zap.sh /usr/local/bin/zap.sh

# ZAP Python scripts from official image
COPY --from=zap-source /zap/zap-baseline.py /usr/local/bin/zap-baseline.py
COPY --from=zap-source /zap/zap-full-scan.py /usr/local/bin/zap-full-scan.py
COPY --from=zap-source /zap/zap-api-scan.py /usr/local/bin/zap-api-scan.py
RUN chmod +x /usr/local/bin/zap-*.py && \
    pip3 install --no-cache-dir --break-system-packages python-owasp-zap-v2.4 || true

# Nuclei
RUN NUCLEI_VERSION=3.7.1 && \
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

# Wordlists (bundled locally to avoid download issues in Docker build)
RUN mkdir -p /usr/share/seclists/Discovery/Web-Content
COPY docker/wordlists/common.txt /usr/share/seclists/Discovery/Web-Content/common.txt

# Stage 2: Rails application
FROM --platform=linux/amd64 ruby:3.2.2-slim AS app

ENV DEBIAN_FRONTEND=noninteractive
ENV APP_ENV=production
ENV RUBY_YJIT_ENABLE=1

# System deps for Rails + Chromium for PDF generation
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libsqlite3-dev \
    default-jre-headless python3 perl libnet-ssleay-perl libjson-perl libxml-writer-perl \
    chromium nodejs npm python3-pip \
    pandoc texlive-xetex texlive-fonts-recommended texlive-latex-extra lmodern \
    curl wget git ca-certificates \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && rm -rf /var/lib/apt/lists/*

# ZAP Python dependencies
RUN pip3 install --no-cache-dir --break-system-packages pyyaml requests python-owasp-zap-v2.4

# Copy security tools from tools stage
COPY --from=tools /opt/zap /opt/zap
COPY --from=tools /usr/local/bin/zap* /usr/local/bin/
# ZAP scripts expect /zap/zap-x.sh — symlink /zap to /opt/zap
RUN ln -sf /opt/zap /zap && mkdir -p /opt/zap/wrk
ENV ZAP_PATH=/opt/zap
ENV PATH="/opt/zap:${PATH}"
COPY --from=tools /usr/local/bin/nuclei /usr/local/bin/
COPY --from=tools /opt/sqlmap /opt/sqlmap
COPY --from=tools /usr/local/bin/sqlmap /usr/local/bin/
COPY --from=tools /usr/local/bin/ffuf /usr/local/bin/
COPY --from=tools /opt/nikto /opt/nikto
RUN ln -sf /opt/nikto/program/nikto.pl /usr/local/bin/nikto && \
    ln -sf /opt/nikto/program/nikto.conf /etc/nikto.conf
COPY --from=tools /usr/share/seclists /usr/share/seclists
# Nuclei templates will be downloaded on first run if not present
RUN mkdir -p /root/nuclei-templates

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

# Install Puppeteer for PDF generation via Grover
RUN echo '{"dependencies":{"puppeteer":"latest"}}' > package.json && \
    PUPPETEER_SKIP_DOWNLOAD=true npm install

# Grover/Puppeteer config for Chromium
ENV GROVER_NO_SANDBOX=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# Database is created at boot (Penetrator.boot! runs migrations)
CMD ["bin/scan"]
