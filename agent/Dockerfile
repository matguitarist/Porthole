# Porthole's agent: a small static binary on an empty image.
#   docker build -t porthole-agent agent/
#   docker run -d --name porthole-agent -p 7080:7080 \
#     -v /var/run/docker.sock:/var/run/docker.sock -v /proc:/host/proc:ro porthole-agent
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
# Dependencies first, so a code change doesn't rebuild them.
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src
COPY src src
COPY web web
RUN touch src/main.rs && cargo build --release && strip target/release/porthole-agent

FROM scratch
COPY --from=build /src/target/release/porthole-agent /porthole-agent
EXPOSE 7080
HEALTHCHECK --interval=30s --timeout=3s CMD ["/porthole-agent", "--health"]
ENTRYPOINT ["/porthole-agent"]
