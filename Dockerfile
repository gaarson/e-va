FROM debian:trixie-slim

# Install system dependencies including luarocks
RUN apt-get update && apt-get install -y --no-install-recommends \
    lua5.1 \
    liblua5.1-0-dev \
    gcc \
    make \
    git \
    curl \
    nodejs \
    npm \
    wget \
    ca-certificates \
    luarocks \
    && rm -rf /var/lib/apt/lists/*

# Install Lua modules
RUN luarocks --lua-version=5.1 install luasocket \
    && luarocks --lua-version=5.1 install inspect \
    && luarocks --lua-version=5.1 install lua-cjson

# Copy source code to agent home
COPY . /opt/e-va

# Build C extensions
WORKDIR /opt/e-va
RUN make

# Make entrypoint executable
RUN chmod +x /opt/e-va/e-va

# Set working directory to workspace
WORKDIR /workspace

# Environment defaults
ENV AGENT_HOME=/opt/e-va
ENV PROJECT_ROOT=/workspace

VOLUME ["/workspace/.e-va-conf"]
ENTRYPOINT ["/opt/e-va/e-va"]
CMD ["--pipe", "."]
