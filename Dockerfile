FROM docker.io/crystallang/crystal:1.20-alpine AS build
WORKDIR /src
COPY shard.yml shard.lock ./
RUN shards install
COPY . .
RUN crystal build src/main.cr --release --static --no-debug -o /github-mirror
RUN file /github-mirror; ldd /github-mirror || true

FROM docker.io/alpine:3.22
RUN apk add --no-cache git ca-certificates
# git-lfs only if you enable FETCH_LFS:
# RUN apk add --no-cache git-lfs
COPY --from=build /github-mirror /usr/local/bin/github-mirror
RUN adduser -D -u 1000 backup
USER backup
ENTRYPOINT ["github-mirror"]
