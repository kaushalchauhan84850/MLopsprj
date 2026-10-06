# Shared image for collector / trainer / analyzer / loadgen.
# Selected at runtime via args, e.g.: python -m src.collector.main
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY src/ src/

ENTRYPOINT ["python", "-m"]
