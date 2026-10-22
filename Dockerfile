FROM python:3.12-alpine
WORKDIR /app
COPY server.py /app/server.py
RUN addgroup -S mcbridge && adduser -S mcbridge -G mcbridge
USER mcbridge
ENV PYTHONUNBUFFERED=1 DB_PATH=/tmp/mcbridge.sqlite3 PORT=8080
EXPOSE 8080
CMD ["python", "/app/server.py"]
