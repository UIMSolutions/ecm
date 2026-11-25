FROM docker.io/library/ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      ldc dub libssl-dev ca-certificates git && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY dub.sdl dub.selections.json ./
COPY source source
COPY tests tests
COPY views views
RUN dub test --compiler=ldc2 && dub build --build=release --compiler=ldc2

FROM docker.io/library/ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /data /app/config && chown 10001:0 /data && chmod -R g=u /data
COPY --from=build /src/build/ecm-backend /usr/local/bin/ecm-backend
COPY config/default.json /app/config/default.json
WORKDIR /app
ENV PORT=8080 ECM_DATA_DIR=/data ECM_CONFIG=/app/config/default.json
USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/ecm-backend"]
