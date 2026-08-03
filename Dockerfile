FROM debian:trixie-slim
LABEL org.opencontainers.image.title="E-va Agent" \
      org.opencontainers.image.description="Autonomous Lua-based AI agent with browser automation" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.vendor="E-va"
STOPSIGNAL SIGQUIT
SHELL ["/bin/bash", "-c"]
# System dependencies + Chrome dependencies
# Added `tini` for process management
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsutils \
    tini \
    lua5.1 \
    liblua5.1-0-dev \
    gcc \
    sudo \
    make \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    nodejs \
    npm \
    luarocks \
    fonts-liberation \
    libasound2t64 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgdk-pixbuf-2.0-0 \
    libnspr4 \
    libnss3 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxshmfence1 \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# Устанавливаем Chrome Stable
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Создаем скрипт-обертку для Chrome
# Это принудительно добавит нужные флаги для работы в Docker независимо от того, как MCP вызывает браузер
RUN mv /usr/bin/google-chrome-stable /usr/bin/google-chrome-stable-orig && \
    echo '#!/bin/bash' > /usr/bin/google-chrome-stable && \
    echo 'exec /usr/bin/google-chrome-stable-orig --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage "$@"' >> /usr/bin/google-chrome-stable && \
    chmod +x /usr/bin/google-chrome-stable

# Создаём непривилегированного пользователя
RUN useradd -m -s /bin/bash chromeuser

# Lua modules
RUN luarocks --lua-version=5.1 install luasocket \
    && luarocks --lua-version=5.1 install inspect \
    && luarocks --lua-version=5.1 install lua-cjson

# Copy source code
COPY . /opt/e-va

# Build C extensions
WORKDIR /opt/e-va
RUN make

RUN chmod +x /opt/e-va/e-va
# Устанавливаем chrome-devtools-mcp
RUN npm install -g chrome-devtools-mcp@latest
WORKDIR /workspace
ENV AGENT_HOME=/opt/e-va
ENV PROJECT_ROOT=/workspace
ENV CHROME_PATH=/usr/bin/google-chrome-stable
ENV EVA_STATUS_PORT=8080
EXPOSE 8080
VOLUME ["/workspace/.e-va-conf"]
# SECURITY: Restrict sudo to only Chrome-related commands
# chromeuser needs sudo only for Chrome sandbox bypass scenarios
# Resource limits: consider using --memory and --cpus flags at runtime
# Example: docker run --memory 4g --cpus 2 e-va-agent
RUN echo "chromeuser ALL=(ALL) NOPASSWD: /usr/bin/google-chrome-stable, /usr/bin/google-chrome-stable-orig" > /etc/sudoers.d/chromeuser \
    && chmod 0440 /etc/sudoers.d/chromeuser
# Create workspace directory with correct ownership BEFORE switching user
RUN mkdir -p /workspace && chown chromeuser:chromeuser /workspace
RUN mkdir -p /opt/e-va/logs && chown chromeuser:chromeuser /opt/e-va/logs
# Copy init script and make it executable
COPY init.sh /opt/e-va/init.sh
RUN chmod +x /opt/e-va/init.sh
# Healthcheck: Verify core binaries exist (does NOT require agent to be running)
# This allows the container to report healthy even during idle periods
# For runtime agent verification, use: pgrep -f 'lua.*agent\.lua'
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["bash", "-c", "test -x /opt/e-va/e-va && test -f /opt/e-va/agent.lua && test -x /usr/bin/google-chrome-stable && test -x /usr/bin/tini || exit 1"]
# Оборачиваем вызов в tini для корректного завершения зомби-процессов Chrome
# init.sh runs as root, fixes workspace ownership, then drops to chromeuser
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/e-va/init.sh"]
CMD ["--pipe", "."]