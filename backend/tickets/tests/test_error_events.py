"""Registro y consulta de fallos de workflows (WF3)."""
from concurrent.futures import ThreadPoolExecutor

from django.db import IntegrityError, connections, transaction
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient

from tickets.models import ErrorEvent

from .helpers import TEST_API_KEY, ApiTestCase

URL = "/api/error-events/"

VALID_EVENT = {
    "workflow_id": "wf-01",
    "workflow_name": "01 - Ticket intake",
    "execution_id": "1234",
    "failed_node": "Create ticket in Django",
    "error_type": "http_5xx",
    "retryable": "yes",
    "message": "Request failed with status code 500",
    "ticket_external_id": "TCK-1001",
}


class ErrorEventCreateTests(ApiTestCase):
    def test_registra_un_evento_valido(self):
        response = self.client.post(URL, VALID_EVENT, format="json")
        self.assertEqual(response.status_code, 201)
        body = response.json()
        self.assertEqual((body["error_type"], body["retryable"]), ("http_5xx", "yes"))
        self.assertEqual(ErrorEvent.objects.count(), 1)

    def test_solo_workflow_name_y_error_type_son_obligatorios(self):
        response = self.client.post(URL, {"workflow_name": "wf", "error_type": "unknown"}, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json()["retryable"], "no")  # valor seguro por defecto

        response = self.client.post(URL, {}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(set(response.json()["details"]), {"workflow_name", "error_type"})

    def test_tipo_de_error_o_retryable_invalidos_devuelven_400(self):
        for field, value in [("error_type", "explosion"), ("retryable", "quizas"), ("workflow_name", 42)]:
            with self.subTest(field=field):
                response = self.client.post(URL, {**VALID_EVENT, field: value}, format="json")
                self.assertEqual(response.status_code, 400)

    def test_el_mensaje_se_redacta_antes_de_guardarse(self):
        message = "SMTP rechazo a ana.lopez@example.com / tel +34 612 345 678"
        response = self.client.post(URL, {**VALID_EVENT, "message": message}, format="json")
        stored = ErrorEvent.objects.get(pk=response.json()["id"]).message
        self.assertEqual(stored, "SMTP rechazo a [email] / tel [phone]")
        self.assertNotIn("ana.lopez", response.content.decode())

    def test_el_mensaje_largo_se_trunca_en_lugar_de_fallar(self):
        response = self.client.post(URL, {**VALID_EVENT, "message": "e" * 5000}, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(len(response.json()["message"]), 500)


class ErrorEventListTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        for i, error_type in enumerate(["http_5xx", "timeout", "http_5xx"]):
            self.client.post(URL, {**VALID_EVENT, "error_type": error_type, "ticket_external_id": f"TCK-{i}", "execution_id": f"ex-{i}"}, format="json")

    def test_lista_primero_los_mas_recientes(self):
        results = self.client.get(URL).json()["results"]
        ids = [r["id"] for r in results]
        self.assertEqual(ids, sorted(ids, reverse=True))
        self.assertEqual(len(results), 3)

    def test_filtra_por_tipo_y_por_ticket(self):
        self.assertEqual(self.client.get(URL, {"error_type": "timeout"}).json()["count"], 1)
        self.assertEqual(self.client.get(URL, {"ticket_external_id": "TCK-2"}).json()["count"], 1)
        self.assertEqual(self.client.get(URL, {"error_type": "smtp"}).json()["count"], 0)

    def test_pagina_con_limit(self):
        body = self.client.get(URL, {"limit": 2}).json()
        self.assertEqual((body["count"], len(body["results"])), (3, 2))
        self.assertIsNotNone(body["next"])


class ErrorEventTicketIdTests(ApiTestCase):
    def test_guarda_el_ticket_afectado(self):
        response = self.client.post(URL, {**VALID_EVENT, "ticket_id": 12, "execution_id": "e-1"}, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json()["ticket_id"], 12)

    def test_ticket_id_es_opcional_y_puede_ser_null(self):
        for payload in ({}, {"ticket_id": None}):
            with self.subTest(payload=payload):
                response = self.client.post(URL, {**VALID_EVENT, "execution_id": "", **payload}, format="json")
                self.assertEqual(response.status_code, 201)
                self.assertIsNone(response.json()["ticket_id"])

    def test_ticket_id_invalido_devuelve_400(self):
        for bad in (0, -5, "abc", True, 1.5, [3], {"a": 1}):
            with self.subTest(bad=bad):
                response = self.client.post(URL, {**VALID_EVENT, "ticket_id": bad}, format="json")
                self.assertEqual(response.status_code, 400, response.content)
                self.assertIn("ticket_id", response.json()["details"])

    def test_filtra_por_ticket_id(self):
        self.client.post(URL, {**VALID_EVENT, "ticket_id": 7, "execution_id": "a"}, format="json")
        self.client.post(URL, {**VALID_EVENT, "ticket_id": 8, "execution_id": "b"}, format="json")
        self.assertEqual(self.client.get(URL, {"ticket_id": 7}).json()["count"], 1)
        self.assertEqual(self.client.get(URL, {"ticket_id": 99}).json()["count"], 0)
        self.assertEqual(self.client.get(URL, {"ticket_id": "no-numero"}).json()["count"], 2)  # filtro ignorado


class ErrorEventIdempotencyTests(ApiTestCase):
    """WF3 puede reintentar el POST: la misma ejecucion de n8n se registra UNA sola vez."""

    def test_repetir_la_misma_ejecucion_devuelve_200_y_no_duplica(self):
        payload = {**VALID_EVENT, "workflow_id": "wf-A", "execution_id": "777"}
        first = self.client.post(URL, payload, format="json")
        second = self.client.post(URL, {**payload, "message": "otro mensaje distinto"}, format="json")
        self.assertEqual((first.status_code, second.status_code), (201, 200))
        self.assertFalse(first.json()["duplicate"])
        self.assertTrue(second.json()["duplicate"])
        self.assertEqual(first.json()["id"], second.json()["id"])
        self.assertEqual(second.json()["message"], VALID_EVENT["message"])  # no se pisa el registro original
        self.assertEqual(ErrorEvent.objects.count(), 1)

    def test_sin_execution_id_no_hay_clave_de_idempotencia(self):
        payload = {**VALID_EVENT, "execution_id": ""}
        self.assertEqual(self.client.post(URL, payload, format="json").status_code, 201)
        self.assertEqual(self.client.post(URL, payload, format="json").status_code, 201)
        self.assertEqual(ErrorEvent.objects.count(), 2)

    def test_la_clave_es_workflow_id_mas_execution_id(self):
        base = {**VALID_EVENT, "execution_id": "100"}
        self.assertEqual(self.client.post(URL, {**base, "workflow_id": "wf-A"}, format="json").status_code, 201)
        self.assertEqual(self.client.post(URL, {**base, "workflow_id": "wf-B"}, format="json").status_code, 201)
        self.assertEqual(self.client.post(URL, {**base, "workflow_id": "wf-A", "execution_id": "101"}, format="json").status_code, 201)
        self.assertEqual(ErrorEvent.objects.count(), 3)

    def test_la_base_de_datos_tambien_lo_impide(self):
        # Defensa en profundidad: aunque se esquivara la API, la restriccion UNIQUE lo rechaza.
        kwargs = dict(workflow_id="wf-A", workflow_name="x", execution_id="55", error_type="unknown")
        ErrorEvent.objects.create(**kwargs)
        with self.assertRaises(IntegrityError), transaction.atomic():
            ErrorEvent.objects.create(**kwargs)
        ErrorEvent.objects.create(**{**kwargs, "execution_id": ""})  # los vacios no cuentan
        ErrorEvent.objects.create(**{**kwargs, "execution_id": ""})


class ErrorEventRaceTests(TransactionTestCase):
    @override_settings(API_KEY=TEST_API_KEY)
    def test_cinco_registros_simultaneos_de_la_misma_ejecucion_dejan_una_fila(self):
        payload = {**VALID_EVENT, "workflow_id": "wf-race", "execution_id": "999"}

        def call(_):
            try:
                client = APIClient()
                client.credentials(HTTP_X_API_KEY=TEST_API_KEY)
                return client.post(URL, payload, format="json").status_code
            finally:
                connections.close_all()

        with ThreadPoolExecutor(max_workers=5) as pool:
            statuses = list(pool.map(call, range(5)))
        self.assertEqual(sorted(statuses), [200, 200, 200, 200, 201])
        self.assertEqual(ErrorEvent.objects.count(), 1)
