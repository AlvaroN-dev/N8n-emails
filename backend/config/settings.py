"""Configuracion de Django.

Todo lo sensible o dependiente del entorno se lee de variables de entorno. Si falta un
secreto obligatorio la aplicacion NO arranca (falla pronto) en lugar de usar un valor
por defecto inseguro.
"""
import os
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent


def env_required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ImproperlyConfigured(f"Falta la variable de entorno obligatoria: {name}")
    return value


def env_bool(name, default=False):
    return os.environ.get(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


def env_list(name, default=""):
    return [item.strip() for item in os.environ.get(name, default).split(",") if item.strip()]


# --- Seguridad ---------------------------------------------------------------------
SECRET_KEY = env_required("DJANGO_SECRET_KEY")
DEBUG = env_bool("DJANGO_DEBUG", False)  # False por defecto: nunca DEBUG=True fuera de pruebas locales
ALLOWED_HOSTS = env_list("DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1,api")

# Clave compartida con n8n (cabecera X-API-Key). Obligatoria: sin ella la API no arranca.
API_KEY = env_required("DJANGO_API_KEY")

# --- Aplicacion --------------------------------------------------------------------
# Superficie minima a proposito: sin admin, sesiones, mensajes ni staticfiles (API JSON pura).
INSTALLED_APPS = [
    "rest_framework",
    "tickets",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

# Herramientas de QA (inyeccion de fallos, y mas adelante un LLM simulado). Apagado por defecto:
# nunca debe activarse fuera de desarrollo/pruebas.
QA_TOOLS_ENABLED = env_bool("QA_TOOLS_ENABLED", False)
if QA_TOOLS_ENABLED:
    MIDDLEWARE.append("qa_tools.middleware.FaultInjectionMiddleware")

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

# --- Base de datos -----------------------------------------------------------------
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": os.environ.get("POSTGRES_DB", "tickets"),
        "USER": os.environ.get("POSTGRES_USER", "tickets"),
        "PASSWORD": env_required("POSTGRES_PASSWORD"),
        "HOST": os.environ.get("POSTGRES_HOST", "postgres"),
        "PORT": os.environ.get("POSTGRES_PORT", "5432"),
        "CONN_MAX_AGE": 60,
        # Comprueba que la conexion reutilizada siga viva (p. ej. tras reiniciar PostgreSQL).
        "CONN_HEALTH_CHECKS": True,
        "OPTIONS": {"connect_timeout": 5},
    }
}

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# --- Internacionalizacion ----------------------------------------------------------
LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = False
USE_TZ = True

# --- Django REST Framework ---------------------------------------------------------
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": ["tickets.auth.ApiKeyAuthentication"],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_PARSER_CLASSES": ["rest_framework.parsers.JSONParser"],
    # No usamos django.contrib.auth: sin usuario para las peticiones anonimas.
    "UNAUTHENTICATED_USER": None,
    "UNAUTHENTICATED_TOKEN": None,
    "EXCEPTION_HANDLER": "tickets.errors.api_exception_handler",
}

# --- Logging -----------------------------------------------------------------------
# Regla del proyecto: los logs NUNCA contienen emails ni el texto de los mensajes de los tickets.
LOG_LEVEL = os.environ.get("DJANGO_LOG_LEVEL", "INFO").upper()

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "plain": {"format": "%(asctime)s %(levelname)s %(name)s %(message)s"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "plain"},
    },
    "root": {
        "handlers": ["console"],
        "level": LOG_LEVEL,
    },
    # El logger `django` (y `django.request`, que registra los 4xx/5xx) trae su propio nivel
    # por defecto; sin esto DJANGO_LOG_LEVEL no lo controlaria.
    "loggers": {
        "django": {"level": LOG_LEVEL},
    },
}
