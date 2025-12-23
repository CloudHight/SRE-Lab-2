from flask import Flask, jsonify
import requests
from opentelemetry import trace
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource

# Initialize tracing
resource = Resource.create({
    "service.name": "sample-app",
    "service.version": "1.0.0",
    "k8s.namespace": "application"
})

trace.set_tracer_provider(TracerProvider(resource=resource))
tracer = trace.get_tracer(__name__)

# OTLP exporter (pointing to our collector)
otlp_exporter = OTLPSpanExporter(
    endpoint="otel-collector.observability.svc.cluster.local:4317",
    insecure=True
)
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

app = Flask(__name__)

# Instrument Flask and Requests
FlaskInstrumentor().instrument_app(app)
RequestsInstrumentor().instrument()

@app.route('/')
def home():
    with tracer.start_as_current_span("home"):
        return jsonify({"status": "ok", "service": "sample-app"})

@app.route('/api')
def api():
    with tracer.start_as_current_span("api"):
        # Simulate external API call
        response = requests.get('http://httpbin.org/json')
        return jsonify({
            "status": "ok",
            "data": response.json(),
            "internal_span": True
        })

@app.route('/health')
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)