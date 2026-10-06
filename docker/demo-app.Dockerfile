FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements-demo.txt .
RUN pip install -r requirements-demo.txt

COPY src/demo_app/ src/demo_app/

ENV ERROR_RATE=0.03 \
    BASE_LATENCY_MS=40

EXPOSE 8080

CMD ["python", "-m", "uvicorn", "src.demo_app.main:app", "--host", "0.0.0.0", "--port", "8080"]
