FROM python:3.13-alpine
COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-cache --python-preference only-system
COPY registry.py ./
ENV PORT=7423
CMD ["sh", "-c", "exec .venv/bin/uvicorn registry:app --host 127.0.0.1 --port $PORT"]
