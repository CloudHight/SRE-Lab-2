FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

ENV OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4317
ENV OTEL_RESOURCE_ATTRIBUTES=service.name=sample-app,service.version=1.0.0

EXPOSE 8080

CMD ["python", "app.py"]