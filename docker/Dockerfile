FROM debian:unstable-slim
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
    lua5.4 \
    liblua5.4-dev \
    gcc \
    sudo \
    make \
    m4 \
    git \
    curl \
    wget \
    ca-certificates \
    gnupg \
    nodejs \
    npm \
    luarocks \
    ripgrep \
    ffmpeg \
    imagemagick \
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
    libssl3t64 \
    zlib1g \
    libzstd1 \
    liblua5.4-0 \
    libcrypt-dev \
    && rm -rf /var/lib/apt/lists/*
# Ensure 'lua' resolves to lua5.4 (Debian default may be lua5.1)
# lua5.1 is already pulled in by nodejs; just switch the alternatives
RUN update-alternatives --set lua-interpreter /usr/bin/lua5.4 && update-alternatives --set lua-compiler /usr/bin/luac5.4
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

ENV LUA_INCDIR=/usr/include/lua5.4
ENV LUA_LIBDIR=/usr/lib/x86_64-linux-gnu
# Lua modules
RUN mkdir -p /opt/e-va/lua_modules && \
    luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules basexx \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules binaryheap \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules busted \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules compat53 \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules cqueues \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules datafile \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules dkjson \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules fifo \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules http \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules inspect \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules json-lua \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules lpeg \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules lpeg_patterns \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules lua-cjson \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules lua-term \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules lua_cliargs \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luacov \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luafilesystem \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luaossl \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luassert \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luasocket \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luasystem \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules mediator_lua \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules penlight \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules say \
    && luarocks --lua-version=5.4 install --tree /opt/e-va/lua_modules luaposix
# Build deps for cage (Wayland compositor) and wayvnc (VNC server)
RUN apt-get update && apt-get install -y --no-install-recommends \
    meson \
    ninja-build \
    libwlroots-0.20-dev \
    libaml-dev \
    libneatvnc-dev \
    libjansson-dev \
    libpixman-1-dev \
    libwayland-dev \
    libgbm-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*
# Copy source code
COPY . /opt/e-va


# Build and install cage from local source
WORKDIR /opt/e-va/docker/cage
RUN meson setup build && ninja -C build && ninja -C build install
# Build neatvnc from source (apt version 1.0.1 is too old, wayvnc needs >=1.1)
RUN git clone --depth 1 https://github.com/any1/neatvnc.git /tmp/neatvnc && \
    cd /tmp/neatvnc && \
    meson setup build --prefix=/usr --libdir=lib/x86_64-linux-gnu && ninja -C build && ninja -C build install && \
    ldconfig && \
    rm -rf /tmp/neatvnc
# Build and install wayvnc from local source
# aml and neatvnc installed via apt (libaml-dev, libneatvnc-dev)
WORKDIR /opt/e-va/docker/wayvnc
RUN PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/share/pkgconfig:$PKG_CONFIG_PATH meson setup build && ninja -C build && ninja -C build install
# Build C extensions
WORKDIR /opt/e-va
RUN make

RUN chmod +x /opt/e-va/e-va
ENV LUA_PATH="/opt/e-va/lua_modules/share/lua/5.4/?.lua;/opt/e-va/lua_modules/share/lua/5.4/?/init.lua"
ENV LUA_CPATH="/opt/e-va/lua_modules/lib/lua/5.4/?.so"
# Устанавливаем chrome-devtools-mcp
RUN npm install -g chrome-devtools-mcp@latest
WORKDIR /workspace
ENV AGENT_HOME=/opt/e-va
ENV PROJECT_ROOT=/workspace
ENV CHROME_PATH=/usr/bin/google-chrome-stable
ENV EVA_STATUS_PORT=8080
EXPOSE 8080
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