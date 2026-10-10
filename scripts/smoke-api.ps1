<#
.SYNOPSIS
    Smoke test de la API Django contra el servidor REAL (gunicorn en Docker).

.DESCRIPTION
    Comprueba salud, autenticacion, alta idempotente, validacion, triage, marca de notificado,
    registro de errores y formato de errores. Lee la API key del archivo .env (nunca la imprime).
    Crea tickets de prueba con external_id "SMOKE-<fecha>-<n>" en la base de datos local.
    Termina con codigo 1 si alguna comprobacion falla.

.PARAMETER BaseUrl
    URL base de la API. Por defecto http://127.0.0.1:8000

.EXAMPLE
    .\scripts\smoke-api.ps1
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8000'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# --- API key desde .env (sin mostrarla) ---
# TT_ENV_FILE permite apuntar a otro entorno (por defecto .env).
$envName = if ($env:TT_ENV_FILE) { $env:TT_ENV_FILE } else { '.env' }
$envFile = Join-Path $root $envName
if (-not (Test-Path -LiteralPath $envFile)) { throw "No existe $envName. Ejecuta .\scripts\setup.ps1" }
$ApiKey = $null
foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
    if ($line -match '^DJANGO_API_KEY=(.+)$') { $ApiKey = $Matches[1].Trim() }
}
if (-not $ApiKey) { throw "DJANGO_API_KEY no esta definida en .env" }

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [string]$Key = $script:ApiKey
    )
    $headers = @{}
    if ($Key) { $headers['X-API-Key'] = $Key }
    $params = @{ Uri = "$BaseUrl$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 20 }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Compress)
        $params.ContentType = 'application/json'
    }
    $status = 0
    $content = ''
    try {
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode
        $content = $r.Content
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }
        $status = [int]$resp.StatusCode
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $content = $_.ErrorDetails.Message                      # PowerShell 7
        }
        else {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())   # Windows PowerShell 5.1
            $content = $reader.ReadToEnd()
            $reader.Dispose()
        }
    }
    $json = $null
    if ($content) { try { $json = $content | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = $status; Json = $json; Raw = $content }
}

$script:failed = 0
$script:passed = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++; Write-Host ("PASS  {0}" -f $Name) }
    else { $script:failed++; Write-Host ("FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
function New-Payload {
    param([string]$Suffix)
    return @{
        external_id    = "SMOKE-$stamp-$Suffix"
        customer_email = 'smoke.test@example.com'
        subject        = 'Smoke test: cannot log in'
        message        = 'This is a synthetic smoke test message to verify the API end to end.'
        source         = 'api'
    }
}

Write-Host "== Smoke test API: $BaseUrl"

# Un error inesperado (API caida, excepcion del script...) debe terminar con codigo != 0,
# nunca como si todo hubiera ido bien.
try {

# 1. Salud (sin autenticacion)
$r = Invoke-Api GET '/api/health/' -Key ''
Assert-That 'health 200 sin autenticacion' ($r.Status -eq 200 -and $r.Json.status -eq 'ok' -and $r.Json.database -eq 'ok') "status=$($r.Status)"

# 2-3. Autenticacion
$r = Invoke-Api POST '/api/tickets/' (New-Payload 'noauth') -Key ''
Assert-That 'sin API key -> 401 unauthorized' ($r.Status -eq 401 -and $r.Json.code -eq 'unauthorized') "status=$($r.Status)"
$r = Invoke-Api POST '/api/tickets/' (New-Payload 'badkey') -Key 'clave-incorrecta'
Assert-That 'API key incorrecta -> 401' ($r.Status -eq 401) "status=$($r.Status)"

# 4-5. Alta e idempotencia
$payload = New-Payload 'a'
$first = Invoke-Api POST '/api/tickets/' $payload
Assert-That 'alta valida -> 201 duplicate=false' ($first.Status -eq 201 -and $first.Json.duplicate -eq $false) "status=$($first.Status) body=$($first.Raw)"
$again = Invoke-Api POST '/api/tickets/' $payload
Assert-That 'mismo external_id -> 200 duplicate=true y mismo id' ($again.Status -eq 200 -and $again.Json.duplicate -eq $true -and $again.Json.id -eq $first.Json.id) "status=$($again.Status)"
$ticketId = $first.Json.id

# 6-7. Validacion
$r = Invoke-Api POST '/api/tickets/' @{}
$fields = @($r.Json.details.PSObject.Properties.Name)
Assert-That 'cuerpo vacio -> 400 con detalle de campos' ($r.Status -eq 400 -and $r.Json.code -eq 'validation_error' -and ($fields -contains 'subject') -and ($fields -contains 'message')) "status=$($r.Status)"
$bad = New-Payload 'badtype'; $bad.subject = [int]12345
$r = Invoke-Api POST '/api/tickets/' $bad
Assert-That 'subject numerico (tipo incorrecto) -> 400' ($r.Status -eq 400 -and ($r.Json.details.PSObject.Properties.Name -contains 'subject')) "status=$($r.Status)"

# 8-11. Consulta, triage, notificado
$r = Invoke-Api GET "/api/tickets/$ticketId/"
Assert-That 'GET ticket -> 200' ($r.Status -eq 200 -and $r.Json.external_id -eq $payload.external_id) "status=$($r.Status)"

$triage = @{ category = 'technical'; priority = 'high'; summary = 'Customer cannot log in (synthetic smoke test).'; source = 'ai' }
$r = Invoke-Api PATCH "/api/tickets/$ticketId/triage/" $triage
Assert-That 'PATCH triage -> 200 status=triaged' ($r.Status -eq 200 -and $r.Json.status -eq 'triaged') "status=$($r.Status) body=$($r.Raw)"
$badTriage = $triage.Clone(); $badTriage.category = 'inventada'
$r = Invoke-Api PATCH "/api/tickets/$ticketId/triage/" $badTriage
Assert-That 'triage con categoria invalida -> 400' ($r.Status -eq 400) "status=$($r.Status)"

$r1 = Invoke-Api POST "/api/tickets/$ticketId/notified/"
$r2 = Invoke-Api POST "/api/tickets/$ticketId/notified/"
Assert-That 'notified: 1a vez already_notified=false, 2a vez true' ($r1.Status -eq 200 -and $r1.Json.already_notified -eq $false -and $r2.Json.already_notified -eq $true) "s1=$($r1.Status) s2=$($r2.Status)"

$other = Invoke-Api POST '/api/tickets/' (New-Payload 'b')
$r = Invoke-Api POST "/api/tickets/$($other.Json.id)/notified/"
Assert-That 'notified sin triage previo -> 409 not_triaged' ($r.Status -eq 409 -and $r.Json.code -eq 'not_triaged') "status=$($r.Status)"

# 12. Registro de errores y redaccion de PII
$ev = @{ workflow_name = 'smoke'; error_type = 'smtp'; retryable = 'manual'; message = 'rechazo para smoke.pii@example.com' }
$r = Invoke-Api POST '/api/error-events/' $ev
Assert-That 'error-event -> 201 con el email redactado' ($r.Status -eq 201 -and $r.Json.message -eq 'rechazo para [email]' -and $r.Raw -notmatch 'smoke\.pii') "status=$($r.Status) body=$($r.Raw)"

# 13. Formato de errores
$r = Invoke-Api GET '/api/no-existe/'
Assert-That 'ruta inexistente -> 404 JSON' ($r.Status -eq 404 -and $r.Json.code -eq 'not_found') "status=$($r.Status)"

}
catch {
    Write-Host "ERROR inesperado: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

Write-Host ("== Resultado: {0} correctas, {1} fallidas" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
