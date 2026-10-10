"""Alta idempotente, consulta, triage y marca de notificado."""
from concurrent.futures import ThreadPoolExecutor

from django.db import connections
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient

from tickets.models import Ticket

from .helpers import TEST_API_KEY, VALID_TICKET, VALID_TRIAGE, ApiTestCase

URL = "/api/tickets/"


class TicketCreateTests(ApiTestCase):
    def test_solicitud_valida_devuelve_201_y_persiste(self):
        response = self.client.post(URL, VALID_TICKET, format="json")
        self.assertEqual(response.status_code, 201)
        body = response.json()
        self.assertFalse(body["duplicate"])
        self.assertEqual(body["external_id"], "TCK-1001")
        self.assertEqual(body["status"], "received")
        self.assertEqual(Ticket.objects.count(), 1)

    def test_source_es_opcional_y_vale_api_por_defecto(self):
        payload = {k: v for k, v in VALID_TICKET.items() if k != "source"}
        self.assertEqual(self.client.post(URL, payload, format="json").json()["source"], "api")

    def test_duplicado_devuelve_200_y_no_crea_otra_fila(self):
        first = self.client.post(URL, VALID_TICKET, format="json")
        second = self.client.post(URL, VALID_TICKET, format="json")
        self.assertEqual((first.status_code, second.status_code), (201, 200))
        self.assertTrue(second.json()["duplicate"])
        self.assertEqual(first.json()["id"], second.json()["id"])
        self.assertEqual(Ticket.objects.count(), 1)

    def test_campos_obligatorios_ausentes_devuelve_400_indicando_cada_campo(self):
        response = self.client.post(URL, {}, format="json")
        self.assertEqual(response.status_code, 400)
        body = response.json()
        self.assertEqual(body["code"], "validation_error")
        for field in ("external_id", "customer_email", "subject", "message"):
            self.assertIn(field, body["details"])
        self.assertNotIn("source", body["details"])  # es opcional
        self.assertEqual(Ticket.objects.count(), 0)

    def test_tipos_incorrectos_devuelven_400(self):
        casos = {
            "subject": 12345,  # DRF lo convertiria a "12345": aqui debe rechazarse
            "message": ["no", "es", "texto"],
            "external_id": 1001,
            "customer_email": 123,
            "source": ["web"],
        }
        for field, value in casos.items():
            with self.subTest(field=field):
                response = self.client.post(URL, {**VALID_TICKET, field: value}, format="json")
                self.assertEqual(response.status_code, 400, response.content)
                self.assertIn(field, response.json()["details"])
        self.assertEqual(Ticket.objects.count(), 0)

    def test_cuerpo_que_no_es_un_objeto_devuelve_400(self):
        for body in ("[]", "null", '"texto"', "42"):
            with self.subTest(body=body):
                response = self.client.post(URL, body, content_type="application/json")
                self.assertEqual(response.status_code, 400)

    def test_valores_fuera_de_rango_devuelven_400(self):
        casos = {
            "customer_email": "no-es-un-email",
            "subject": "ab",  # minimo 3
            "message": "corto",  # minimo 10
            "external_id": "tiene espacios",
            "source": "fax",
        }
        for field, value in casos.items():
            with self.subTest(field=field):
                response = self.client.post(URL, {**VALID_TICKET, field: value}, format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn(field, response.json()["details"])

    def test_longitudes_maximas(self):
        casos = {"subject": "x" * 201, "message": "x" * 5001, "external_id": "A" * 65}
        for field, value in casos.items():
            with self.subTest(field=field):
                response = self.client.post(URL, {**VALID_TICKET, field: value}, format="json")
                self.assertEqual(response.status_code, 400)

    def test_caracteres_de_control_devuelven_400_y_no_un_500(self):
        casos = [
            ("message", "hola\x00mundo con nul"),  # NUL: PostgreSQL daria 500 (lo frena DRF)
            ("message", "texto con campana\x07 de control"),  # control no permitido en multilinea
            ("subject", "Asunto\r\nBcc: atacante@example.com"),  # inyeccion de cabeceras de correo
            ("external_id", "TCK\x00-1"),
        ]
        for field, value in casos:
            with self.subTest(field=field, value=value):
                response = self.client.post(URL, {**VALID_TICKET, field: value}, format="json")
                self.assertEqual(response.status_code, 400, response.content)

    def test_mensaje_multilinea_es_valido(self):
        payload = {**VALID_TICKET, "message": "Linea uno del problema.\nLinea dos con detalle.\tFin"}
        self.assertEqual(self.client.post(URL, payload, format="json").status_code, 201)

    def test_los_espacios_alrededor_se_recortan(self):
        ticket = self.create_ticket(external_id="  TCK-2000  ", subject="   Asunto con espacios   ")
        self.assertEqual(ticket["external_id"], "TCK-2000")
        self.assertEqual(ticket["subject"], "Asunto con espacios")


class DuplicateRaceTests(TransactionTestCase):
    """Peticiones simultaneas con el mismo external_id: debe quedar UN ticket (T14)."""

    @override_settings(API_KEY=TEST_API_KEY)
    def test_cinco_peticiones_en_paralelo_crean_un_unico_ticket(self):
        def call(_):
            try:
                client = APIClient()
                client.credentials(HTTP_X_API_KEY=TEST_API_KEY)
                return client.post(URL, VALID_TICKET, format="json").status_code
            finally:
                connections.close_all()  # cada hilo tiene su propia conexion

        with ThreadPoolExecutor(max_workers=5) as pool:
            statuses = list(pool.map(call, range(5)))

        self.assertEqual(sorted(statuses), [200, 200, 200, 200, 201])
        self.assertEqual(Ticket.objects.count(), 1)


class TicketDetailTests(ApiTestCase):
    def test_devuelve_el_ticket(self):
        ticket = self.create_ticket()
        response = self.client.get(f"{URL}{ticket['id']}/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["subject"], VALID_TICKET["subject"])

    def test_inexistente_devuelve_404_json(self):
        response = self.client.get(f"{URL}999999/")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json()["code"], "not_found")


class TicketTriageTests(ApiTestCase):
    def test_guarda_el_triage_y_avanza_el_estado(self):
        ticket = self.create_ticket()
        response = self.triage_ticket(ticket["id"])
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual((body["category"], body["priority"], body["triage_source"]), ("technical", "high", "ai"))
        self.assertEqual(body["status"], "triaged")
        self.assertIsNotNone(body["triaged_at"])

    def test_registra_el_fallback_con_su_motivo(self):
        ticket = self.create_ticket()
        response = self.triage_ticket(ticket["id"], source="fallback", reason="ai_output_invalid")
        self.assertEqual(response.json()["triage_source"], "fallback")
        self.assertEqual(response.json()["triage_reason"], "ai_output_invalid")

    def test_valores_invalidos_devuelven_400_y_no_modifican_el_ticket(self):
        ticket = self.create_ticket()
        casos = [
            {"category": "inventada"},
            {"priority": "critica"},
            {"source": "humano"},
            {"summary": ""},
            {"summary": "x" * 281},
            {"summary": "linea1\nlinea2"},
            {"summary": 123},
        ]
        for override in casos:
            with self.subTest(override=override):
                self.assertEqual(self.triage_ticket(ticket["id"], **override).status_code, 400)
        self.assertEqual(self.client.get(f"{URL}{ticket['id']}/").json()["status"], "received")

    def test_faltan_campos_devuelve_400(self):
        ticket = self.create_ticket()
        response = self.client.patch(f"{URL}{ticket['id']}/triage/", {"category": "billing"}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertIn("priority", response.json()["details"])

    def test_ticket_inexistente_devuelve_404(self):
        self.assertEqual(self.triage_ticket(999999).status_code, 404)

    def test_repetir_el_triage_es_idempotente(self):
        ticket = self.create_ticket()
        self.assertEqual(self.triage_ticket(ticket["id"]).status_code, 200)
        self.assertEqual(self.triage_ticket(ticket["id"]).status_code, 200)

    def test_un_triage_posterior_no_retrocede_un_ticket_notificado(self):
        ticket = self.create_ticket()
        self.triage_ticket(ticket["id"])
        self.client.post(f"{URL}{ticket['id']}/notified/")
        response = self.triage_ticket(ticket["id"], priority="low")
        self.assertEqual(response.json()["status"], "notified")
        self.assertIsNotNone(response.json()["notified_at"])

    def test_solo_acepta_patch(self):
        ticket = self.create_ticket()
        self.assertEqual(self.client.post(f"{URL}{ticket['id']}/triage/", VALID_TRIAGE, format="json").status_code, 405)


class TicketNotifiedTests(ApiTestCase):
    def test_primera_marca_gana_y_la_segunda_informa_ya_notificado(self):
        ticket = self.create_ticket()
        self.triage_ticket(ticket["id"])

        first = self.client.post(f"{URL}{ticket['id']}/notified/")
        second = self.client.post(f"{URL}{ticket['id']}/notified/")

        self.assertEqual(first.status_code, 200)
        self.assertFalse(first.json()["already_notified"])
        self.assertTrue(second.json()["already_notified"])
        self.assertEqual(first.json()["notified_at"], second.json()["notified_at"])  # la fecha no se pisa
        self.assertEqual(self.client.get(f"{URL}{ticket['id']}/").json()["status"], "notified")

    def test_sin_triage_previo_devuelve_409(self):
        ticket = self.create_ticket()
        response = self.client.post(f"{URL}{ticket['id']}/notified/")
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["code"], "not_triaged")
        self.assertIsNone(self.client.get(f"{URL}{ticket['id']}/").json()["notified_at"])

    def test_ticket_inexistente_devuelve_404(self):
        self.assertEqual(self.client.post(f"{URL}999999/notified/").status_code, 404)
