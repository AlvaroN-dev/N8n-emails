from django.test import override_settings
from rest_framework.test import APITestCase

# Clave de prueba (no es un secreto real): se inyecta con override_settings.
TEST_API_KEY = "test-api-key-not-a-real-secret"

VALID_TICKET = {
    "external_id": "TCK-1001",
    "customer_email": "ana@example.com",
    "subject": "Cannot log in",
    "message": "I cannot log in to my account since this morning, please help.",
    "source": "web",
}

VALID_TRIAGE = {
    "category": "technical",
    "priority": "high",
    "summary": "Customer cannot log in since this morning.",
    "source": "ai",
}


@override_settings(API_KEY=TEST_API_KEY)
class ApiTestCase(APITestCase):
    """Base: todas las peticiones llevan la API key correcta salvo que el test la quite."""

    def setUp(self):
        self.client.credentials(HTTP_X_API_KEY=TEST_API_KEY)

    def create_ticket(self, **overrides):
        payload = {**VALID_TICKET, **overrides}
        response = self.client.post("/api/tickets/", payload, format="json")
        self.assertIn(response.status_code, (200, 201), response.content)
        return response.json()

    def triage_ticket(self, ticket_id, **overrides):
        payload = {**VALID_TRIAGE, **overrides}
        return self.client.patch(f"/api/tickets/{ticket_id}/triage/", payload, format="json")
