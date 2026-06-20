FROM alpine:3.21

RUN apk add --no-cache python3

COPY injector.py /usr/local/bin/injector.py

EXPOSE 8025

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8025/healthz || exit 1

ENTRYPOINT ["python3", "/usr/local/bin/injector.py"]
