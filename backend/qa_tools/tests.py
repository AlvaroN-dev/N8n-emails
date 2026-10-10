"""Pruebas de la inyeccion de fallos. El middleware se instala solo dentro de estos tests."""
from unittest import mock

from django.conf import settings
from django.test import override_settings

from tickets.models import Ticket
from tickets.tests.helpers import VALID_TICKET, ApiTestCase

MIDDLEWARE_PATH = "qa_tools.middleware.FaultInjectionMiddleware"

# Exactamente UNA instancia del middleware, este o no QA_TOOLS_ENABLED en el entorno.
_MIDDLEWARE = [m for m in settings.MIDDLEWARE if m != MIDDLEWARE_PATH] + [MIDDLEWARE_PATH]


@override_settings(MIDDLEWARE=_MIDDLEWARE)
class FaultInjectionTests(ApiTestCase):
    def post(self, **overrides):
        return self.client.post("/api/tickets/", {**VALID_TICKET, **overrides}, format="json")

    def test_prefijo_qa_500_devuelve_500_y_no_crea_el_ticket(self):
        response = self.post(external_id="QA-500-demo")
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json()["code"], "internal_error")
        self.assertEqual(Ticket.objects.count(), 0)

    def test_prefijo_qa_slow_espera_y_despues_crea_el_ticket(self):
        with mock.patch("qa_tools.middleware.time.sleep") as fake_sleep:
            response = self.post(external_id="QA-SLOW-demo")
        fake_sleep.assert_called_once_with(15)
        self.assertEqual(response.status_code, 201)  # el servidor termina aunque el cliente ya se rindiera
        self.assertEqual(Ticket.objects.count(), 1)

    def test_el_reenvio_de_un_qa_slow_ya_creado_no_vuelve_a_esperar(self):
        with mock.patch("qa_tools.middleware.time.sleep") as fake_sleep:
            first = self.post(external_id="QA-SLOW-demo")
            second = self.post(external_id="QA-SLOW-demo")
        self.assertEqual((first.status_code, second.status_code), (201, 200))
        fake_sleep.assert_called_once_with(15)  # solo la primera vez
        self.assertEqual(Ticket.objects.count(), 1)

    def test_un_external_id_normal_no_se_ve_afectado(self):
        with mock.patch("qa_tools.middleware.time.sleep") as fake_sleep:
            self.assertEqual(self.post().status_code, 201)
        fake_sleep.assert_not_called()

    def test_solo_actua_en_el_alta_de_tickets(self):
        self.assertEqual(self.client.get("/api/health/").status_code, 200)
        self.assertEqual(self.client.get("/api/error-events/").status_code, 200)

    def test_cuerpo_invalido_no_rompe_el_middleware(self):
        for body in ("{no es json", "[]", "null", '{"external_id": 123}'):
            with self.subTest(body=body):
                response = self.client.post("/api/tickets/", body, content_type="application/json")
                self.assertEqual(response.status_code, 400)
