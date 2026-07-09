# docker-rai/auth/Dockerfile
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Минимальные системные пакеты + CA
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Корпоративный корневой сертификат (если нужен) — вы уже его добавляли
COPY usiag.crt /usr/local/share/ca-certificates/usiag.crt
RUN update-ca-certificates

# Скажем pip использовать этот сертификат
ENV PIP_CERT=/usr/local/share/ca-certificates/usiag.crt

WORKDIR /app
COPY requirements.txt ./requirements.txt

# Установка зависимостей: больше таймаут, ретраи, prefer-binary, несколько попыток
# (иногда сети «плывут», поэтому даём до 3 попыток)
RUN set -eux; \
    for i in 1 2 3; do \
        pip install --default-timeout=600 --retries 10 --prefer-binary \
            --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org \
            -r requirements.txt && break || (echo "pip failed ($i), retrying..." && sleep 5); \
    done

COPY app.py ./app.py
COPY templates ./templates

EXPOSE 5000
CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]
