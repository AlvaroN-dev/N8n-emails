from django.urls import path

from . import llm_mock

urlpatterns = [
    # Base URL a configurar en la credencial de n8n: http://api:8000/qa/llm/v1
    path("llm/v1/chat/completions", llm_mock.chat_completions),
]
