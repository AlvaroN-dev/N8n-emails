from django.db import models


class Ticket(models.Model):
    """Solicitud de soporte recibida por el webhook de n8n.

    `external_id` es la referencia del cliente y es UNICA: garantiza la idempotencia
    (el mismo ticket enviado dos veces no se duplica).
    """

    class Source(models.TextChoices):
        WEB = "web"
        EMAIL = "email"
        API = "api"

    class Status(models.TextChoices):
        RECEIVED = "received"
        TRIAGED = "triaged"
        NOTIFIED = "notified"

    class Category(models.TextChoices):
        BILLING = "billing"
        TECHNICAL = "technical"
        ACCOUNT = "account"
        FEATURE_REQUEST = "feature_request"
        OTHER = "other"

    class Priority(models.TextChoices):
        LOW = "low"
        MEDIUM = "medium"
        HIGH = "high"
        URGENT = "urgent"

    class TriageSource(models.TextChoices):
        AI = "ai"
        FALLBACK = "fallback"  # clasificacion por reglas cuando la IA falla o devuelve algo invalido

    external_id = models.CharField(max_length=64, unique=True)
    customer_email = models.EmailField()
    subject = models.CharField(max_length=200)
    message = models.TextField()
    source = models.CharField(max_length=10, choices=Source.choices, default=Source.API)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.RECEIVED)

    # Resultado del triage (vacio hasta que WF2 lo guarda).
    category = models.CharField(max_length=20, choices=Category.choices, blank=True)
    priority = models.CharField(max_length=10, choices=Priority.choices, blank=True)
    summary = models.CharField(max_length=280, blank=True)
    triage_source = models.CharField(max_length=10, choices=TriageSource.choices, blank=True)
    triage_reason = models.CharField(max_length=200, blank=True)
    triaged_at = models.DateTimeField(null=True, blank=True)
    notified_at = models.DateTimeField(null=True, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f"{self.external_id} ({self.status})"


class ErrorEvent(models.Model):
    """Fallo de un workflow de n8n, ya saneado (sin datos personales), registrado por WF3."""

    class ErrorType(models.TextChoices):
        HTTP_4XX = "http_4xx"
        HTTP_5XX = "http_5xx"
        TIMEOUT = "timeout"
        CONNECTION = "connection"
        VALIDATION = "validation"
        AI_OUTPUT = "ai_output"
        SMTP = "smtp"
        UNKNOWN = "unknown"

    class Retryable(models.TextChoices):
        NO = "no"  # reintentar no ayuda (p. ej. 4xx): hay que corregir el dato o la configuracion
        YES = "yes"  # operacion idempotente: se puede reprocesar con seguridad
        MANUAL = "manual"  # tiene efectos laterales (p. ej. correo): decide una persona

    workflow_id = models.CharField(max_length=64, blank=True)
    workflow_name = models.CharField(max_length=200)
    execution_id = models.CharField(max_length=64, blank=True)
    failed_node = models.CharField(max_length=200, blank=True)
    error_type = models.CharField(max_length=20, choices=ErrorType.choices)
    retryable = models.CharField(max_length=10, choices=Retryable.choices, default=Retryable.NO)
    message = models.CharField(max_length=500, blank=True)
    # Ticket afectado, cuando se conoce: permite reprocesarlo (POST /webhook/internal/ticket-triage {"ticket_id": N}).
    ticket_id = models.PositiveBigIntegerField(null=True, blank=True, db_index=True)
    ticket_external_id = models.CharField(max_length=64, blank=True, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-id"]
        constraints = [
            # Una ejecucion de n8n que falla se registra UNA vez: asi WF3 puede reintentar el POST sin duplicar eventos.
            models.UniqueConstraint(
                fields=["workflow_id", "execution_id"],
                condition=~models.Q(execution_id=""),
                name="uniq_error_event_per_execution",
            ),
        ]

    def __str__(self):
        return f"{self.workflow_name}: {self.error_type}"
