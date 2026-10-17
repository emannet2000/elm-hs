# Build the Haskell API with an isolated container package store.
FROM haskell:9.10.3-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build/api
COPY api/ ./
RUN cabal update \
    && cabal build exe:ecc-crm-api --disable-executable-dynamic -j2 \
    && cabal test auth-tests --disable-executable-dynamic -j2 \
    && mkdir -p /out \
    && cp "$(cabal list-bin exe:ecc-crm-api --disable-executable-dynamic)" /out/ecc-crm-api

# Match the builder's Debian release without shipping the compiler.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 ca-certificates libgmp10 libnuma1 libffi8 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home ecc
WORKDIR /app
COPY --from=build /out/ecc-crm-api /app/ecc-crm-api
COPY api/migrations/ /app/migrations/
# The compiled Elm frontend is already committed to this repository.
COPY web/dist/ /app/web/
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    WEB_DIST=/app/web \
    SEED_DEMO=false \
    PORT=10000
USER ecc
EXPOSE 10000
CMD ["/app/ecc-crm-api"]
