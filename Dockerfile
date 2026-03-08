# ==========================================
# STAGE 1: Builder
# ==========================================
FROM debian:bookworm-slim AS builder

# Установка зависимостей для сборки
RUN apt-get update && apt-get install -y \
    lua5.1 \
    liblua5.1-0-dev \
    luarocks \
    gcc \
    make \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . .

# Компиляция C-модуля
RUN make

# Локальная установка Lua-зависимостей (включая зависимости для тестов и http, если нужно)
# JSON и http_request упоминались в твоих скриптах
RUN luarocks install busted --tree=lua_modules
RUN luarocks install luajson --tree=lua_modules
# RUN luarocks install lua-http --tree=lua_modules # Раскомментируй, если используешь

# ==========================================
# STAGE 2: Secure Runtime
# ==========================================
FROM debian:bookworm-slim AS runtime

# Установка только runtime-утилит (ripgrep критичен для tool_executor.lua)
RUN apt-get update && apt-get install -y \
    lua5.1 \
    ripgrep \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Security Best Practice: Создаем непривилегированного пользователя
RUN useradd -m -s /bin/bash agent
USER agent

# Директория для самого агента
WORKDIR /opt/e-va

# Копируем только артефакты (без исходников C, Makefile и лишнего мусора)
COPY --from=builder --chown=agent:agent /build/e-va ./e-va
COPY --from=builder --chown=agent:agent /build/*.lua ./
COPY --from=builder --chown=agent:agent /build/patcher_core.so ./
COPY --from=builder --chown=agent:agent /build/lua_modules ./lua_modules

# Настраиваем переменные окружения для Lua
ENV LUA_PATH="/opt/e-va/?.lua;/opt/e-va/lua_modules/share/lua/5.1/?.lua;/opt/e-va/lua_modules/share/lua/5.1/?/init.lua;;"
ENV LUA_CPATH="/opt/e-va/?.so;/opt/e-va/lua_modules/lib/lua/5.1/?.so;;"

# Создаем рабочую директорию, куда будем монтировать код пользователя
RUN mkdir -p /home/agent/workspace
WORKDIR /home/agent/workspace

# Точка входа
ENTRYPOINT ["lua", "/opt/e-va/agent.lua"]
