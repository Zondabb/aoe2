FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . ./multiplayer_service_python/

ENV AOE2_MP_HOST=0.0.0.0
ENV AOE2_MP_PORT=8001
EXPOSE 8001
USER 65532:65532
CMD ["python", "-m", "multiplayer_service_python.main"]
