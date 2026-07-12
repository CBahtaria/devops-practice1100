# Stage 1: Builder — installs deps and pre-warms embedding model
FROM python:3.14-slim AS builder
ARG EMBEDDING_MODEL=BAAI/bge-large-en-v1.5
ARG CACHE_BUST=1

WORKDIR /app
COPY pyproject.toml requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir sentence-transformers fastembed && \
    for i in 1 2 3; do \
        python -c "from sentence_transformers import SentenceTransformer; \
        SentenceTransformer('${EMBEDDING_MODEL}', cache_folder='/app/models'); \
        print('Model ready.')" && break || \
        (echo "Attempt ${i} failed, retrying in 5s..." && sleep 5); \
    done && \
    pip install --no-cache-dir -r requirements.txt

# Stage 2: Runtime — production, non-root, read-only-safe
FROM python:3.14-slim AS runtime

RUN adduser --uid 10001 --disabled-password --gecos "" brt

COPY --from=builder /app/models /app/models
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin /usr/local/bin

WORKDIR /app
COPY brt_platform/ ./brt_platform/
COPY pyproject.toml ./

RUN chown -R brt:brt /app

USER brt
VOLUME ["/tmp"]
ENV TMPDIR=/tmp
ENV SENTENCE_TRANSFORMERS_HOME=/app/models
ENV PYTHONUNBUFFERED=1
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

CMD ["uvicorn", "brt_platform.api.server:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]

# Stage 3: Dev — hot-reload
FROM runtime AS dev
USER root
RUN pip install --no-cache-dir watchfiles pytest pytest-asyncio httpx ruff
USER brt
CMD ["uvicorn", "brt_platform.api.server:app", "--reload", "--host", "0.0.0.0", "--port", "8000"]
