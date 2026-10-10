import re

from rest_framework import serializers

from .models import ErrorEvent, Ticket
from .privacy import redact_pii

# Caracteres de control prohibidos. En textos de una linea se prohiben todos (evita inyeccion de
# cabeceras si el valor acaba en el asunto de un correo); en textos multilinea se permiten \t \n \r.
# (El CharField de DRF ya rechaza por su cuenta el NUL \x00, que haria fallar a PostgreSQL con un 500.)
_CONTROL_SINGLE_LINE = re.compile(r"[\x00-\x1f\x7f]")
_CONTROL_MULTI_LINE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

_EXTERNAL_ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class StrictCharField(serializers.CharField):
    """CharField que solo acepta cadenas JSON.

    El CharField de DRF convierte numeros a texto (12345 -> "12345"), lo que dejaria pasar
    tipos incorrectos como si fueran validos.
    """

    def __init__(self, *, multiline=False, **kwargs):
        self.multiline = multiline
        super().__init__(**kwargs)

    def to_internal_value(self, data):
        if not isinstance(data, str):
            self.fail("invalid")
        value = super().to_internal_value(data)
        pattern = _CONTROL_MULTI_LINE if self.multiline else _CONTROL_SINGLE_LINE
        if pattern.search(value):
            raise serializers.ValidationError("Control characters are not allowed.")
        return value


class TicketCreateSerializer(serializers.Serializer):
    external_id = StrictCharField(max_length=64)
    customer_email = serializers.EmailField(max_length=254)
    subject = StrictCharField(min_length=3, max_length=200)
    message = StrictCharField(min_length=10, max_length=5000, multiline=True)
    source = serializers.ChoiceField(choices=Ticket.Source.choices, default=Ticket.Source.API)

    def validate_external_id(self, value):
        if not _EXTERNAL_ID_RE.match(value):
            raise serializers.ValidationError("Only letters, digits, '.', '_' and '-' are allowed.")
        return value


class TicketSerializer(serializers.ModelSerializer):
    """Representacion de salida de un ticket."""

    class Meta:
        model = Ticket
        fields = [
            "id", "external_id", "customer_email", "subject", "message", "source", "status",
            "category", "priority", "summary", "triage_source", "triage_reason",
            "triaged_at", "notified_at", "created_at",
        ]
        read_only_fields = fields


class TriageSerializer(serializers.Serializer):
    category = serializers.ChoiceField(choices=Ticket.Category.choices)
    priority = serializers.ChoiceField(choices=Ticket.Priority.choices)
    summary = StrictCharField(min_length=1, max_length=280)
    source = serializers.ChoiceField(choices=Ticket.TriageSource.choices)
    reason = StrictCharField(max_length=200, required=False, allow_blank=True, default="")


class ErrorEventSerializer(serializers.ModelSerializer):
    # Declarados explicitamente: `message` se TRUNCA y redacta (un reporte de error no debe
    # fallar por ser largo) y los textos deben ser cadenas reales.
    workflow_id = StrictCharField(max_length=64, required=False, allow_blank=True, default="")
    workflow_name = StrictCharField(max_length=200)
    execution_id = StrictCharField(max_length=64, required=False, allow_blank=True, default="")
    failed_node = StrictCharField(max_length=200, required=False, allow_blank=True, default="")
    message = StrictCharField(required=False, allow_blank=True, default="", multiline=True)
    ticket_external_id = StrictCharField(max_length=64, required=False, allow_blank=True, default="")
    ticket_id = serializers.IntegerField(required=False, allow_null=True, min_value=1, default=None)

    class Meta:
        model = ErrorEvent
        fields = [
            "id", "workflow_id", "workflow_name", "execution_id", "failed_node",
            "error_type", "retryable", "message", "ticket_id", "ticket_external_id", "created_at",
        ]
        read_only_fields = ["id", "created_at"]
        # La unicidad por ejecucion NO es un error de validacion: el POST es idempotente (ver ErrorEventListCreateView).
        validators = []

    def validate_message(self, value):
        # Defensa en profundidad: aunque el workflow ya sanea, Django nunca guarda correos ni telefonos.
        return redact_pii(value)[:500]
