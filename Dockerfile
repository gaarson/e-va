FROM debian:trixie-slim

# Системные зависимости + Chrome зависимости
# Добавили `tini` для управления процессами
RUN apt-get update && apt-get install -y --no-install-recommends \
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

VOLUME ["/workspace/.e-va-conf"]

RUN echo "chromeuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/chromeuser \
    && chmod 0440 /etc/sudoers.d/chromeuser

USER chromeuser

# Оборачиваем вызов в tini для корректного завершения зомби-процессов Chrome
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/e-va/e-va"]
CMD ["--pipe", "."]
