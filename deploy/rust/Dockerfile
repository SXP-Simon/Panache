# 从仓库根目录构建；预先执行 flutter build web --release。
FROM rust:1.94.1-bookworm AS build
WORKDIR /source
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY backend/VERSION ./backend/VERSION
RUN cargo build --locked --release -p handwriting-server

FROM debian:bookworm-slim
RUN useradd --uid 10001 --create-home handwriting && mkdir /data && chown handwriting /data
WORKDIR /opt/handwriting
COPY --from=build /source/target/release/handwriting-server ./
COPY app/build/web ./web
COPY backend/font_assets ./font_assets
COPY backend/VERSION ./VERSION
COPY crates/handwriting-core/NOTICE ./NOTICE
COPY crates/handwriting-core/licenses ./licenses
USER handwriting
ENV HANDWRITING_LISTEN_ADDR=0.0.0.0:5006 HANDWRITING_DATA_DIR=/data
EXPOSE 5006
VOLUME ["/data"]
ENTRYPOINT ["/opt/handwriting/handwriting-server"]
