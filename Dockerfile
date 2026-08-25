# Build Docker.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/chemistry
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
# Both binaries come out of ONE image, env-switched: the game runs
# /bin/chemistry, every policy runs /bin/chemistry-player with either
# PLAYER_PROMPT or PLAYER_SCRIPTED set.
RUN nim c $NimFlags --nimcache:/tmp/chemistry-nimcache \
      --out:chemistry src/chemistry.nim && \
    nim c $NimFlags --nimcache:/tmp/chemistry-player-nimcache \
      --out:chemistry-player src/chemistry_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/chemistry
COPY --from=build /workspace/chemistry/chemistry /bin/chemistry
COPY --from=build /workspace/chemistry/chemistry-player /bin/chemistry-player
COPY --from=build /workspace/chemistry/*.json ./
COPY --from=build /workspace/chemistry/data ./data

CMD ["/bin/chemistry"]
