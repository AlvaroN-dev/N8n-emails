"""Salud, autenticacion, formato de errores, privacidad en logs y redaccion de PII."""
from unittest import mock

from django.db import OperationalError
from django.test import SimpleTestCase, override_settings
from rest_framework.test import APIClient

from tickets.privacy import redact_pii

from .helpers import TEST_API_KEY, VALID_TICKET, ApiTestCase


class HealthTests(ApiTestCase):
    def test_health_ok_sin_autenticacion(self):
        response = APIClient().get("/api/health/")  # cliente sin credenciales
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok", "database": "ok"})

    def test_health_devuelve_503_si_la_base_de_datos_falla(self):
        with mock.patch("tickets.views.connection") as fake_connection:
            fake_connection.cursor.side_effect = OperationalError("db down")
            response = APIClient().get("/api/health/")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json(), {"status": "error", "database": "unavailable"})


class AuthenticationTests(ApiTestCase):
    def test_sin_api_key_devuelve_401_con_cabecera_www_authenticate(self):
        response = APIClient().post("/api/tickets/", VALID_TICKET, format="json")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["code"], "unauthorized")
        self.assertIn("WWW-Authenticate", response.headers)

    def test_api_key_incorrecta_devuelve_401(self):
        client = APIClient()
        client.credentials(HTTP_X_API_KEY="otra-clave")
        response = client.post("/api/tickets/", VALID_TICKET, format="json")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["code"], "unauthorized")

    def test_api_key_correcta_permite_el_acceso(self):
        client = APIClient()
        client.credentials(HTTP_X_API_KEY=TEST_API_KEY)
        self.assertEqual(client.post("/api/tickets/", VALID_TICKET, format="json").status_code, 201)

    def test_falla_cerrado_si_el_servidor_no_tiene_clave_configurada(self):
        # Una cabecera cualquiera NO debe autenticar si API_KEY esta vacia.
        with override_settings(API_KEY=""):
            client = APIClient()
            client.credentials(HTTP_X_API_KEY="cualquiera")
            self.assertEqual(client.get("/api/error-events/").status_code, 401)

    def test_todos_los_endpoints_protegidos_exigen_clave(self):
        client = APIClient()
        for method, url in [
            ("get", "/api/tickets/1/"),
            ("patch", "/api/tickets/1/triage/"),
            ("post", "/api/tickets/1/notified/"),
            ("get", "/api/error-events/"),
            ("post", "/api/error-events/"),
        ]:
            with self.subTest(method=method, url=url):
                self.assertEqual(getattr(client, method)(url).status_code, 401)


class ErrorFormatTests(ApiTestCase):
    def test_ruta_inexistente_devuelve_json_404(self):
        response = self.client.get("/api/no-existe/")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json()["code"], "not_found")

    def test_metodo_no_permitido_devuelve_405_json(self):
        response = self.client.delete("/api/tickets/")
        self.assertEqual(response.status_code, 405)
        self.assertEqual(response.json()["code"], "method_not_allowed")

    def test_content_type_no_json_devuelve_415(self):
        response = self.client.post("/api/tickets/", "x=1", content_type="application/x-www-form-urlencoded")
        self.assertEqual(response.status_code, 415)
        self.assertEqual(response.json()["code"], "unsupported_media_type")

    def test_json_malformado_devuelve_400_parse_error(self):
        response = self.client.post("/api/tickets/", "{not json", content_type="application/json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["code"], "parse_error")

    def test_excepcion_inesperada_devuelve_500_json_sin_filtrar_datos_ni_logs(self):
        secreto = "ana@example.com SUPER-SECRETO"
        with mock.patch("tickets.views.get_object_or_404", side_effect=RuntimeError(secreto)):
            with self.assertLogs("tickets.errors", level="ERROR") as logs:
                response = self.client.get("/api/tickets/1/")

        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.json()["code"], "internal_error")
        self.assertNotIn("SUPER-SECRETO", response.content.decode())
        log_text = "\n".join(logs.output)
        self.assertIn("RuntimeError", log_text)  # se registra el TIPO...
        self.assertNotIn("SUPER-SECRETO", log_text)  # ...pero nunca el mensaje
        self.assertNotIn("ana@example.com", log_text)


class LoggingPrivacyTests(ApiTestCase):
    def test_los_logs_no_contienen_email_ni_texto_del_ticket(self):
        with self.assertLogs("tickets", level="INFO") as logs:
            self.create_ticket()
        log_text = "\n".join(logs.output)
        self.assertIn("external_id=TCK-1001", log_text)  # si hay trazabilidad por id
        self.assertNotIn(VALID_TICKET["customer_email"], log_text)
        self.assertNotIn(VALID_TICKET["message"], log_text)
        self.assertNotIn(VALID_TICKET["subject"], log_text)


class RedactPiiTests(SimpleTestCase):
    def test_redacta_correos(self):
        self.assertEqual(redact_pii("fallo para ana.lopez+x@example.co.uk ok"), "fallo para [email] ok")

    def test_redacta_telefonos(self):
        self.assertEqual(redact_pii("llamar al +34 612 345 678 hoy"), "llamar al [phone] hoy")
        self.assertEqual(redact_pii("tel (555) 123-4567 fin"), "tel [phone] fin")

    def test_redacta_telefonos_seguidos_de_puntuacion(self):
        # Regresion: un telefono al final de una frase quedaba SIN redactar (privacidad).
        self.assertEqual(redact_pii("llamame al +34 612 345 678."), "llamame al [phone].")
        self.assertEqual(redact_pii("tel (555) 123-4567, gracias"), "tel [phone], gracias")
        self.assertEqual(redact_pii("al 612345678; o al 698765432!"), "al [phone]; o al [phone]!")

    def test_no_redacta_decimales_largos_ni_ips_con_punto_final(self):
        for text in ("valor 1.123456789 ok", "total 123456789.5 euros", "fallo en 172.20.0.3:8000.", "version 2.42.6."):
            self.assertEqual(redact_pii(text), text, text)

    def test_no_destruye_ips_ni_versiones(self):
        texto = "connect ECONNREFUSED 172.20.0.3:8000 en n8n 2.42.6"
        self.assertEqual(redact_pii(texto), texto)

    def test_texto_sin_datos_personales_queda_igual(self):
        self.assertEqual(redact_pii("Request failed with status code 500"), "Request failed with status code 500")
