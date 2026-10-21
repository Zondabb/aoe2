FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . ./multiplayer_service_python/

ENV AOE2_MP_HOST=0.0.0.0
ENV AOE2_MP_PORT=8001
ENV AOE2_MP_LEADERBOARD_DB=/data/leaderboard.sqlite3
EXPOSE 8001
RUN mkdir -p /data && chown 65532:65532 /data
USER 65532:65532
CMD ["python", "-m", "multiplayer_service_python.main"]
