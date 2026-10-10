from django.conf import settings
from django.urls import include, path

urlpatterns = [
    path("api/", include("tickets.urls")),
]

# Herramientas de QA (LLM simulado). Solo existen si QA_TOOLS_ENABLED=true: en caso contrario
# estas rutas devuelven 404, como cualquier otra ruta inexistente.
if settings.QA_TOOLS_ENABLED:
    urlpatterns.append(path("qa/", include("qa_tools.urls")))

# Respuestas JSON (y no paginas HTML) para rutas inexistentes y errores fuera de DRF.
handler404 = "tickets.errors.not_found"
handler500 = "tickets.errors.server_error"
