import hmac

from django.conf import settings
from rest_framework import authentication, exceptions


class ServiceUser:
    """Identidad del cliente de servicio (n8n) autenticado con la API key.

    No es un usuario de Django: el proyecto no usa django.contrib.auth.
    """

    is_authenticated = True
    is_active = True
    username = "service"


class ApiKeyAuthentication(authentication.BaseAuthentication):
    """Autenticacion por cabecera `X-API-Key`, comparada en tiempo constante."""

    header = "X-API-Key"

    def authenticate(self, request):
        provided = request.headers.get(self.header)
        if not provided:
            return None  # sin cabecera: la capa de permisos responde 401

        expected = settings.API_KEY
        # Falla cerrado: si el servidor no tiene clave configurada, nunca se autentica a nadie.
        if not expected or not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
            raise exceptions.AuthenticationFailed("Invalid API key.")
        return (ServiceUser(), None)

    def authenticate_header(self, request):
        # Hace que DRF responda 401 (y no 403) a las peticiones sin credenciales validas.
        return "ApiKey"
