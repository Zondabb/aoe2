FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8765

ENV AOE2_AI_HOST=0.0.0.0
ENV AOE2_AI_PORT=8765

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8765"]
