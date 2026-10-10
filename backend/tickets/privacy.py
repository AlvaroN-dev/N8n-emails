"""Utilidades de privacidad: eliminar datos personales de textos que se van a guardar o registrar."""
import re

# Direcciones de correo.
_EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")

# Numeros con al menos 9 digitos, con hasta 2 separadores entre digitos (espacio, parentesis, guion).
# Sin puntos ENTRE digitos: asi una IP (172.20.0.3) o una version (2.42.6) NO se tratan como telefono.
# Un punto FINAL de frase si se admite ("llamame al +34 612 345 678."), pero no un punto seguido de digito (decimal):
# `(?!\w|\.\d)`. Un `(?![\w.])` dejaba SIN redactar los telefonos al final de una frase.
# Tambien puede redactar fechas como 2026-10-09 11:36: pecar de redactar de mas es lo seguro.
_PHONE_RE = re.compile(r"(?<![\w.])(?:\+|\()?\d(?:[\s()-]{0,2}\d){8,}(?!\w|\.\d)")


def redact_pii(text):
    """Sustituye correos y telefonos por marcadores. Pecar de redactar de mas es lo seguro."""
    text = _EMAIL_RE.sub("[email]", text)
    return _PHONE_RE.sub("[phone]", text)
