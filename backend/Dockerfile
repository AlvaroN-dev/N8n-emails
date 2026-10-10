FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Usuario sin privilegios: el proceso no corre como root dentro del contenedor.
RUN useradd --system --uid 10001 --no-create-home appuser

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

USER appuser
EXPOSE 8000

# `sh` explicito: en Windows no se conserva el bit de ejecucion de los archivos.
ENTRYPOINT ["sh", "/app/entrypoint.sh"]

# gunicorn (no `runserver`). --worker-tmp-dir en memoria: recomendado en contenedores.
CMD ["gunicorn", "config.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2", \
     "--timeout", "30", \
     "--worker-tmp-dir", "/dev/shm", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
