# Build the Haskell API with an isolated container package store.
FROM haskell:9.10.3-bookworm AS backend-build
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

# Build the Elm SPA from source so production can never serve a stale
# web/dist that was compiled on a developer workstation.
FROM node:22-bookworm-slim AS frontend-build
RUN npm install --global elm@0.19.1-6
WORKDIR /build/web
COPY web/elm.json ./elm.json
COPY web/src/ ./src/
COPY web/public/ ./public/
RUN mkdir -p dist/css dist/icons \
    && elm make src/Main.elm --optimize --output=dist/main.js \
    && cp public/*.html public/*.js dist/ \
    && cp public/css/*.css dist/css/ \
    && cp public/icons/*.png dist/icons/

# Match the backend builder's Debian release without shipping compilers.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 ca-certificates libgmp10 libnuma1 libffi8 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home ecc
WORKDIR /app
COPY --from=backend-build /out/ecc-crm-api /app/ecc-crm-api
COPY api/migrations/ /app/migrations/
COPY --from=frontend-build /build/web/dist/ /app/web/
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    WEB_DIST=/app/web \
    SEED_DEMO=false \
    PORT=10000
USER ecc
EXPOSE 10000
CMD ["/app/ecc-crm-api"]
