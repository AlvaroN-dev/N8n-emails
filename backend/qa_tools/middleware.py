"""Inyeccion de fallos para pruebas de QA. NO forma parte del comportamiento normal de la API.

Solo se instala si QA_TOOLS_ENABLED=true (ver config/settings.py; apagado por defecto).
Permite reproducir de forma DETERMINISTA fallos del servicio desde un cliente externo (n8n)
sin tocar los workflows: el comportamiento lo decide el prefijo del `external_id` del ticket.

    QA-500-*   -> la API responde 500 sin crear el ticket.
    QA-SLOW-*  -> la API espera SLOW_SECONDS y despues crea el ticket con normalidad
                  (simula un timeout AMBIGUO: el cliente se rinde, pero el servidor termina).
"""
import json
import logging
import time

from django.http import JsonResponse

logger = logging.getLogger(__name__)

SLOW_SECONDS = 15
_MAX_BODY_BYTES = 64 * 1024


class FaultInjectionMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
        logger.warning("QA_TOOLS_ENABLED=true: inyeccion de fallos ACTIVA (solo para desarrollo y pruebas)")

    def __call__(self, request):
        if request.method == "POST" and request.path == "/api/tickets/":
            external_id = self._external_id(request)
            if external_id.startswith("QA-500-"):
                logger.warning("qa_fault_injected kind=http_500 path=%s", request.path)
                return JsonResponse(
                    {"status": "error", "code": "internal_error", "message": "Injected failure (QA)."},
                    status=500,
                )
            # Lento solo la PRIMERA vez (el ticket aun no existe): asi un reenvio del mismo external_id,
            # tras el timeout, se atiende con normalidad y se puede probar la recuperacion.
            if external_id.startswith("QA-SLOW-") and not self._ticket_exists(external_id):
                logger.warning("qa_fault_injected kind=slow seconds=%s path=%s", SLOW_SECONDS, request.path)
                time.sleep(SLOW_SECONDS)
        return self.get_response(request)

    @staticmethod
    def _ticket_exists(external_id):
        from tickets.models import Ticket  # import tardio: el middleware se carga antes que las apps

        return Ticket.objects.filter(external_id=external_id).exists()

    @staticmethod
    def _external_id(request):
        try:
            if len(request.body) > _MAX_BODY_BYTES:
                return ""
            data = json.loads(request.body)
        except (ValueError, UnicodeDecodeError):
            return ""
        value = data.get("external_id") if isinstance(data, dict) else ""
        return value if isinstance(value, str) else ""
