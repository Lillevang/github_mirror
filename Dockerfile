# Static, musl-linked binary built in the Alpine Crystal image. Crystal's
# --static is supported on musl and fragile on glibc, so the build is done
# here rather than on the host; `task dist` extracts the binary from this
# stage for the GitHub release and `task image` ships the runtime stage.
FROM docker.io/crystallang/crystal:1.20-alpine AS build
WORKDIR /src
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src ./src
RUN crystal build src/main.cr --release --static --no-debug -o /github-mirror
# Strip symbols (--no-debug still leaves them in) and fail the build if the
# result is not actually static.
RUN apk add --no-cache file binutils && strip /github-mirror && file /github-mirror | grep -q 'statically linked'

FROM docker.io/alpine:3.22
LABEL org.opencontainers.image.title="github-mirror" \
      org.opencontainers.image.description="Keeps local bare mirrors of every GitHub repository a token can see" \
      org.opencontainers.image.source="https://github.com/Lillevang/github_mirror" \
      org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache git ca-certificates
# git-lfs only if you enable FETCH_LFS:
# RUN apk add --no-cache git-lfs
COPY --from=build /github-mirror /usr/local/bin/github-mirror
RUN adduser -D -u 1000 backup
USER backup
ENV MIRROR_DIR=/data
ENTRYPOINT ["github-mirror"]
