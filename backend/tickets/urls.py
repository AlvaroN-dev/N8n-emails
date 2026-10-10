from django.urls import path

from . import views

urlpatterns = [
    path("health/", views.HealthView.as_view()),
    path("tickets/", views.TicketCreateView.as_view()),
    path("tickets/<int:pk>/", views.TicketDetailView.as_view()),
    path("tickets/<int:pk>/triage/", views.TicketTriageView.as_view()),
    path("tickets/<int:pk>/notified/", views.TicketNotifiedView.as_view()),
    path("error-events/", views.ErrorEventListCreateView.as_view()),
]
