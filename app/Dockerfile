FROM python:3.12-slim

RUN pip install --no-cache-dir "psycopg[binary]==3.2.3" \
 && useradd --uid 10001 --no-create-home app

WORKDIR /srv
COPY app.py .

USER 10001
EXPOSE 8080
ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
