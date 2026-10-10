import logging

from django.db import connection, IntegrityError
from django.db import Error as DatabaseError
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.pagination import LimitOffsetPagination
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .errors import error_response
from .models import ErrorEvent, Ticket
from .serializers import (
    ErrorEventSerializer,
    TicketCreateSerializer,
    TicketSerializer,
    TriageSerializer,
)

# Regla del proyecto: en los logs solo ids y codigos; nunca emails ni texto de los tickets.
logger = logging.getLogger(__name__)


class HealthView(APIView):
    """Comprobacion de salud: la API responde y la base de datos acepta consultas."""

    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
        except DatabaseError:
            logger.error("health_check database=unavailable")
            return Response({"status": "error", "database": "unavailable"}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
        return Response({"status": "ok", "database": "ok"})


class TicketCreateView(APIView):
    """Crea un ticket de forma idempotente (clave: `external_id`)."""

    def post(self, request):
        serializer = TicketCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        data = dict(serializer.validated_data)
        external_id = data.pop("external_id")
        # get_or_create resuelve la carrera entre peticiones simultaneas con el mismo
        # external_id apoyandose en la restriccion UNIQUE de la base de datos.
        ticket, created = Ticket.objects.get_or_create(external_id=external_id, defaults=data)

        logger.info("ticket_%s id=%s external_id=%s", "created" if created else "duplicate", ticket.pk, ticket.external_id)
        body = dict(TicketSerializer(ticket).data, duplicate=not created)
        return Response(body, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


class TicketDetailView(APIView):
    def get(self, request, pk):
        ticket = get_object_or_404(Ticket, pk=pk)
        return Response(TicketSerializer(ticket).data)


class TicketTriageView(APIView):
    """Guarda el resultado del triage (IA o reglas). Idempotente: repetirlo sobrescribe con el mismo dato."""

    http_method_names = ["patch", "options"]

    def patch(self, request, pk):
        ticket = get_object_or_404(Ticket, pk=pk)
        serializer = TriageSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        ticket.category = data["category"]
        ticket.priority = data["priority"]
        ticket.summary = data["summary"]
        ticket.triage_source = data["source"]
        ticket.triage_reason = data["reason"]
        ticket.triaged_at = timezone.now()
        ticket.save(update_fields=[
            "category", "priority", "summary", "triage_source", "triage_reason", "triaged_at", "updated_at",
        ])
        # Avance de estado condicional: nunca retrocede un ticket que ya fue notificado.
        Ticket.objects.filter(pk=ticket.pk, status=Ticket.Status.RECEIVED).update(status=Ticket.Status.TRIAGED)
        ticket.refresh_from_db()

        logger.info("ticket_triaged id=%s source=%s category=%s priority=%s",
                    ticket.pk, ticket.triage_source, ticket.category, ticket.priority)
        return Response(TicketSerializer(ticket).data)


class TicketNotifiedView(APIView):
    """Marca el ticket como notificado una sola vez (guardia anti-duplicados de WF2)."""

    def post(self, request, pk):
        now = timezone.now()
        # UPDATE atomico: solo uno de varios intentos simultaneos "gana" la marca.
        claimed = Ticket.objects.filter(
            pk=pk, notified_at__isnull=True, triaged_at__isnull=False,
        ).update(notified_at=now, status=Ticket.Status.NOTIFIED, updated_at=now)

        ticket = get_object_or_404(Ticket, pk=pk)
        if claimed:
            logger.info("ticket_notified id=%s", ticket.pk)
            return Response({"already_notified": False, "notified_at": ticket.notified_at})
        if ticket.notified_at is not None:
            return Response({"already_notified": True, "notified_at": ticket.notified_at})
        return error_response(
            "not_triaged", "The ticket must be triaged before it can be marked as notified.",
            status.HTTP_409_CONFLICT,
        )


class ErrorEventPagination(LimitOffsetPagination):
    default_limit = 50
    max_limit = 200


class ErrorEventListCreateView(generics.ListCreateAPIView):
    """Registro (POST) y consulta (GET) de fallos de workflows.

    Filtros: error_type, workflow_name, ticket_external_id, ticket_id.
    El POST es IDEMPOTENTE por (workflow_id, execution_id): repetirlo devuelve el evento existente (200) en lugar de
    duplicarlo (201 solo si es nuevo). Asi WF3 puede reintentar el registro con seguridad.
    """

    serializer_class = ErrorEventSerializer
    pagination_class = ErrorEventPagination

    def get_queryset(self):
        queryset = ErrorEvent.objects.all()
        for field in ("error_type", "workflow_name", "ticket_external_id"):
            value = self.request.query_params.get(field)
            if value:
                queryset = queryset.filter(**{field: value})
        ticket_id = self.request.query_params.get("ticket_id")
        if ticket_id and ticket_id.isdigit():
            queryset = queryset.filter(ticket_id=int(ticket_id))
        return queryset

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        def existing_event():
            if not data.get("execution_id"):
                return None  # sin id de ejecucion no hay clave de idempotencia
            return ErrorEvent.objects.filter(
                workflow_id=data.get("workflow_id", ""), execution_id=data["execution_id"],
            ).first()

        event = existing_event()
        created = event is None
        if created:
            try:
                event = serializer.save()
            except IntegrityError:  # otra peticion identica gano la carrera (restriccion UNIQUE de la base de datos)
                event = existing_event()
                created = False
        if created:
            logger.info("error_event id=%s workflow=%s type=%s retryable=%s",
                        event.pk, event.workflow_name, event.error_type, event.retryable)
        body = dict(self.get_serializer(event).data, duplicate=not created)
        return Response(body, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)
