"""Formato unico de errores de la API y manejo controlado de excepciones.

Todas las respuestas de error tienen la forma:
    {"status": "error", "code": "<codigo_estable>", "message": "...", "details": {...}}

Las excepciones inesperadas NUNCA devuelven ni registran su mensaje: puede contener datos
personales (p. ej. el detalle de una violacion de integridad de PostgreSQL).
"""
import logging
import traceback

from django.http import JsonResponse
from rest_framework import exceptions, status
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler

logger = logging.getLogger(__name__)

# Se mapea por codigo HTTP (y no por tipo de excepcion) porque DRF tambien convierte
# Http404 y PermissionDenied de Django en respuestas 404/403.
_CODES_BY_STATUS = {
    status.HTTP_400_BAD_REQUEST: "bad_request",
    status.HTTP_401_UNAUTHORIZED: "unauthorized",
    status.HTTP_403_FORBIDDEN: "forbidden",
    status.HTTP_404_NOT_FOUND: "not_found",
    status.HTTP_405_METHOD_NOT_ALLOWED: "method_not_allowed",
    status.HTTP_406_NOT_ACCEPTABLE: "not_acceptable",
    status.HTTP_415_UNSUPPORTED_MEDIA_TYPE: "unsupported_media_type",
    status.HTTP_429_TOO_MANY_REQUESTS: "throttled",
}


def error_body(code, message, details=None):
    body = {"status": "error", "code": code, "message": message}
    if details is not None:
        body["details"] = details
    return body


def error_response(code, message, http_status, details=None):
    return Response(error_body(code, message, details), status=http_status)


def api_exception_handler(exc, context):
    response = drf_exception_handler(exc, context)

    if response is None:
        # Excepcion inesperada: se registra el TIPO y el lugar, nunca el mensaje.
        frame = traceback.extract_tb(exc.__traceback__)[-1] if exc.__traceback__ else None
        location = f"{frame.filename}:{frame.lineno}" if frame else "unknown"
        logger.error("unhandled_exception type=%s location=%s", type(exc).__name__, location)
        return error_response("internal_error", "Internal server error.", status.HTTP_500_INTERNAL_SERVER_ERROR)

    if isinstance(exc, exceptions.ValidationError):
        response.data = error_body("validation_error", "Invalid request data.", response.data)
    else:
        if isinstance(exc, exceptions.ParseError):
            code = "parse_error"
        else:
            code = _CODES_BY_STATUS.get(response.status_code, "error")
        message = response.data.get("detail", "Error.") if isinstance(response.data, dict) else "Error."
        response.data = error_body(code, str(message))
    return response


def not_found(request, exception=None):
    return JsonResponse(error_body("not_found", "Not found."), status=404)


def server_error(request):
    return JsonResponse(error_body("internal_error", "Internal server error."), status=500)
