FROM swift:6.3-noble AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product WakTrainerServer --static-swift-stdlib

FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 libxml2 tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --user-group --create-home --home-dir /app vapor
WORKDIR /app
COPY --from=build --chown=vapor:vapor /build/.build/release/WakTrainerServer ./
USER vapor:vapor
EXPOSE 8080
ENTRYPOINT ["./WakTrainerServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0"]
