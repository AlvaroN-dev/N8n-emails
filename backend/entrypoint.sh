#!/bin/sh
# Aplica las migraciones y despues ejecuta el comando del contenedor (gunicorn, tests, shell...).
# Las migraciones al arrancar son una comodidad de desarrollo local; en produccion se ejecutan
# como un paso de despliegue separado.
set -eu

python manage.py migrate --noinput
exec "$@"
