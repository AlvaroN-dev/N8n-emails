<#
.SYNOPSIS
    Guia paso a paso para hacer las 13 capturas de pantalla del README y guardarlas con el nombre correcto.

.DESCRIPTION
    Para cada captura el script prepara la pantalla (ejecuta los comandos o abre la pagina), te dice que debe verse,
    espera a que hagas la captura con Win+Shift+S y, al pulsar Enter, guarda la imagen del portapapeles como PNG en
    docs\screenshots\<nombre>.png. Las capturas las haces TU con tu instancia real: el script no genera ni edita imagenes.

    Los tokens y claves se leen de .env sin mostrarse nunca. Usa solo datos sinteticos (ana@example.com).
    Requiere el stack en marcha (docker compose up -d --wait) y los workflows importados (scripts\import-n8n.ps1).

.PARAMETER Desde
    Numero de captura por el que empezar (para retomar). Por defecto 1.

.PARAMETER Pasos
    Lista de capturas concretas a repetir, p. ej. -Pasos 6,7.

.PARAMETER SinEsperas
    Modo de prueba: ejecuta los comandos sin pedir capturas ni abrir el navegador.

.EXAMPLE
    .\scripts\demo-capturas.ps1
    .\scripts\demo-capturas.ps1 -Pasos 11,12
#>
[CmdletBinding()]
param([int]$Desde = 1, [int[]]$Pasos = @(), [switch]$SinEsperas)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$outDir = Join-Path $root 'docs\screenshots'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not $SinEsperas -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Ejecuta este script con Windows PowerShell (powershell.exe), que usa el modo STA necesario para leer el portapapeles.'
}

# ---- configuracion (los secretos se leen de .env y NO se imprimen) -----------------------------------------
function Get-EnvValue([string]$Name) {
    $m = Select-String -Path (Join-Path $root '.env') -Pattern ("^{0}=(.*)$" -f $Name)
    if (-not $m) { throw "Falta $Name en .env" }
    return $m.Matches[0].Groups[1].Value
}
$token = Get-EnvValue 'INTAKE_WEBHOOK_TOKEN'
$key = Get-EnvValue 'DJANGO_API_KEY'
$n8n = 'http://localhost:5678'
$api = 'http://127.0.0.1:8000'
$mail = 'http://localhost:8025'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:lastTicket = $null

function Send-Json([hashtable]$Body) {
    $json = $Body | ConvertTo-Json
    return Invoke-RestMethod "$n8n/webhook/tickets" -Method Post -Headers @{ 'X-Webhook-Token' = $token } `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}
function Clear-Screen { if (-not $SinEsperas) { Clear-Host } }
# Muestra por pantalla (Write-Host, no por el pipeline) el codigo HTTP y el cuerpo JSON de un error; devuelve solo el codigo.
function Show-HttpError($err) {
    $code = 0
    if ($err.Exception.Response) { $code = [int]$err.Exception.Response.StatusCode }
    Write-Host ("HTTP {0}" -f $code) -ForegroundColor Yellow
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
        $text = $err.ErrorDetails.Message
        try { $text = (($err.ErrorDetails.Message | ConvertFrom-Json) | ConvertTo-Json -Depth 6) } catch { }
        Write-Host $text
    }
    return $code
}
function Show-Cmd([string]$Text) { Write-Host ("PS> " + $Text) -ForegroundColor Cyan }

function Save-Clipboard([string]$Path) {
    $img = [System.Windows.Forms.Clipboard]::GetImage()
    if ($null -eq $img) { return $false }
    try { $img.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
    return $true
}
function Wait-Capture([string]$File, [string]$Expect) {
    $path = Join-Path $outDir $File
    if ($SinEsperas) { Write-Host ("   (modo prueba: no se pide captura) -> {0}" -f $File) -ForegroundColor DarkGray; return }
    [System.Windows.Forms.Clipboard]::Clear()
    Write-Host ''
    Write-Host '  >>> HAZ LA CAPTURA AHORA: pulsa Win+Shift+S, selecciona la zona y vuelve a esta ventana.' -ForegroundColor Yellow
    Write-Host ("      Debe verse: {0}" -f $Expect)
    while ($true) {
        $r = Read-Host '      Pulsa Enter cuando la hayas hecho (escribe s + Enter para saltar esta captura)'
        if ($r -eq 's') { Write-Host ("      Saltada: {0}" -f $File) -ForegroundColor DarkYellow; return }
        if (Save-Clipboard $path) { Write-Host ("      Guardada: docs\screenshots\{0}" -f $File) -ForegroundColor Green; return }
        Write-Host '      No hay ninguna imagen en el portapapeles. Repite Win+Shift+S y pulsa Enter.' -ForegroundColor Red
    }
}
function Open-Page([string]$Url) {
    if ($SinEsperas) { Write-Host ("   (modo prueba: no se abre {0})" -f $Url) -ForegroundColor DarkGray; return }
    Write-Host ("  Abriendo {0}" -f $Url) -ForegroundColor Cyan
    Start-Process $Url
}
function Start-Step([int]$N, [string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host ("CAPTURA {0:00} de 13 - {1}" -f $N, $Title) -ForegroundColor Green
    Write-Host ('=' * 78)
}
function Want([int]$N) {
    if ($Pasos.Count -gt 0) { return ($Pasos -contains $N) }
    return ($N -ge $Desde)
}

# ---- comprobaciones previas -----------------------------------------------------------------------------
Write-Host 'Comprobando que el stack esta en marcha...'
$health = Invoke-RestMethod "$api/api/health/"
if ($health.status -ne 'ok') { throw 'La API no responde. Ejecuta: docker compose up -d --wait' }
Write-Host 'OK. Antes de empezar: usa una ventana de terminal amplia, cierra lo que no quieras que salga y NO captures .env ni claves.' -ForegroundColor Gray
if (-not $SinEsperas) { Read-Host 'Pulsa Enter para empezar' | Out-Null }

# ---- 01 ------------------------------------------------------------------------------------------------------
if (Want 1) {
    Start-Step 1 'docker compose ps con los 4 servicios healthy'
    Clear-Screen
    Show-Cmd 'docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"'
    docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
    Wait-Capture '01-compose-ps.png' 'los 4 servicios (api, mailpit, n8n, postgres) con estado "healthy"'
}
# ---- 02 a 05 (n8n) ------------------------------------------------------------------------------------------
if (Want 2) {
    Start-Step 2 'Lista de workflows de n8n'
    Open-Page "$n8n/home/workflows"
    Write-Host '  Inicia sesion si te lo pide. Deben verse los 3 workflows: 01 - Ticket intake, 02 - AI triage and notification y 03 - Error monitoring.'
    Wait-Capture '02-n8n-workflows.png' 'la lista con los 3 workflows (publicados)'
}
if (Want 3) {
    Start-Step 3 'Lienzo de 01 - Ticket intake'
    Open-Page "$n8n/workflow/wfTicketIntake01"
    Write-Host '  Pulsa la tecla 1 (o el boton de ajustar a la vista) para que se vea todo el flujo.'
    Wait-Capture '03-wf01-canvas.png' 'el lienzo completo de 01 - Ticket intake'
}
if (Want 4) {
    Start-Step 4 'Lienzo de 02 - AI triage and notification'
    Open-Page "$n8n/workflow/wfAiTriageNotify"
    Write-Host '  Pulsa la tecla 1 para ajustar a la vista. Debe verse el nodo OpenAI Chat Model colgando de Triage with AI.'
    Wait-Capture '04-wf02-canvas.png' 'el lienzo completo de 02 - AI triage and notification'
}
if (Want 5) {
    Start-Step 5 'Lienzo de 03 - Error monitoring'
    Open-Page "$n8n/workflow/wfErrorMonitor03"
    Write-Host '  Pulsa la tecla 1 para ajustar a la vista.'
    Wait-Capture '05-wf03-canvas.png' 'el lienzo completo de 03 - Error monitoring'
}
# ---- 06 ------------------------------------------------------------------------------------------------------
if (Want 6) {
    Start-Step 6 'Alta valida (accepted) y duplicado (duplicate)'
    Clear-Screen
    $ticket = @{ external_id = "DEMO-$stamp"; customer_email = 'ana@example.com'; subject = 'No puedo pagar mi factura'
                 message = 'Me sale un error al pagar mi factura y necesito ayuda cuanto antes.' }
    Show-Cmd 'Invoke-RestMethod http://localhost:5678/webhook/tickets -Method Post -Headers @{ ''X-Webhook-Token'' = $token } -Body $ticket   # alta valida'
    $r1 = Send-Json $ticket
    $r1 | Format-List
    $script:lastTicket = $r1.ticket_id
    Show-Cmd '(el mismo envio otra vez)   # duplicado'
    $r2 = Send-Json $ticket
    $r2 | Format-List
    Wait-Capture '06-respuesta-201.png' 'la respuesta "accepted" y debajo la de "duplicate" (misma external_id)'
}
# ---- 07 ------------------------------------------------------------------------------------------------------
if (Want 7) {
    Start-Step 7 'Validacion: 400 validation_error'
    Clear-Screen
    Show-Cmd 'Invoke-RestMethod http://localhost:5678/webhook/tickets -Method Post -Headers @{ ''X-Webhook-Token'' = $token } -Body $ticketSinAsunto   # falta "subject"'
    try { Send-Json @{ external_id = "DEMO-400-$stamp"; customer_email = 'ana@example.com'; message = 'Falta el asunto a proposito para ver la validacion.' } | Out-Null; Write-Host 'Inesperado: no dio error' -ForegroundColor Red }
    catch { Show-HttpError $_ | Out-Null }
    Wait-Capture '07-validacion-400.png' 'HTTP 400 y el JSON con code validation_error y el detalle del campo subject'
}
# ---- 08 ------------------------------------------------------------------------------------------------------
if (Want 8) {
    Start-Step 8 'Correo de triage en Mailpit'
    $msg = $null
    try { $msg = (Invoke-RestMethod "$mail/api/v1/messages?limit=1").messages | Select-Object -First 1 } catch { }
    if ($msg) { Open-Page ("{0}/view/{1}" -f $mail, $msg.ID) } else { Open-Page $mail }
    Write-Host '  Debe verse el correo abierto: asunto "[PRIORIDAD] Ticket #N (DEMO-...)", de triage@tickets.local a support-team@example.test, con categoria, prioridad y resumen.'
    Wait-Capture '08-mailpit.png' 'el correo de triage abierto en Mailpit'
}
# ---- 09 ------------------------------------------------------------------------------------------------------
if (Want 9) {
    Start-Step 9 'Ticket clasificado y notificado (GET /api/tickets/{id}/)'
    Clear-Screen
    if (-not $script:lastTicket) {
        $script:lastTicket = (Invoke-RestMethod "$n8n/webhook/tickets" -Method Post -Headers @{ 'X-Webhook-Token' = $token } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes((@{ external_id = "DEMO-9-$stamp"; customer_email = 'ana@example.com'; subject = 'No puedo pagar mi factura'; message = 'Me sale un error al pagar mi factura y necesito ayuda.' } | ConvertTo-Json)))).ticket_id
    }
    $deadline = (Get-Date).AddSeconds(60); $t = $null
    while ((Get-Date) -lt $deadline) {
        $t = Invoke-RestMethod "$api/api/tickets/$($script:lastTicket)/" -Headers @{ 'X-API-Key' = $key }
        if ($t.status -eq 'notified') { break }
        Start-Sleep -Seconds 2
    }
    Show-Cmd ("Invoke-RestMethod http://127.0.0.1:8000/api/tickets/{0}/ -Headers @{{ 'X-API-Key' = `$key }}" -f $script:lastTicket)
    $t | Select-Object id, external_id, status, category, priority, summary, triage_source, notified_at | Format-List
    Wait-Capture '09-ticket-notified.png' 'status notified, con category, priority, summary y triage_source'
}
# ---- 10 ------------------------------------------------------------------------------------------------------
if (Want 10) {
    Start-Step 10 'Ejecuciones en verde en n8n'
    Open-Page "$n8n/home/executions"
    Write-Host '  Deben verse arriba las ejecuciones mas recientes de 01 - Ticket intake y 02 - AI triage and notification en estado Success (verde).'
    Wait-Capture '10-ejecuciones-ok.png' 'la lista de ejecuciones con WF1 y WF2 en verde'
}
# ---- 11 ------------------------------------------------------------------------------------------------------
if (Want 11) {
    Start-Step 11 'Un fallo y la ejecucion de WF3 que lo registra'
    Clear-Screen
    Show-Cmd 'Invoke-RestMethod ... -Body @{ external_id = ''QA-500-...''; ... }   # Django falla a proposito (herramienta de QA)'
    $code = 0
    try { Send-Json @{ external_id = "QA-500-$stamp"; customer_email = 'ana@example.com'; subject = 'Prueba de fallo'; message = 'Provocando un error de Django a proposito para ver la monitorizacion.' } | Out-Null; Write-Host 'Inesperado: no dio error. Comprueba QA_TOOLS_ENABLED=true en .env.' -ForegroundColor Red }
    catch { $code = Show-HttpError $_ }
    Start-Sleep -Seconds 6
    Open-Page "$n8n/home/executions"
    Write-Host '  Deben verse arriba: una ejecucion de 01 - Ticket intake en ERROR (roja) y una de 03 - Error monitoring en Success justo despues.'
    Wait-Capture '11-fallo-y-wf3.png' 'WF1 en error (rojo) y debajo/encima la ejecucion de WF3 (Success)'
}
# ---- 12 ------------------------------------------------------------------------------------------------------
if (Want 12) {
    Start-Step 12 'Evento de error registrado (GET /api/error-events/)'
    Clear-Screen
    Show-Cmd 'Invoke-RestMethod "http://127.0.0.1:8000/api/error-events/?limit=1" -Headers @{ ''X-API-Key'' = $key }'
    $ev = Invoke-RestMethod "$api/api/error-events/?limit=1" -Headers @{ 'X-API-Key' = $key }
    $ev.results | Select-Object workflow_name, failed_node, error_type, retryable, message, ticket_external_id, created_at | Format-List
    Wait-Capture '12-error-events.png' 'el evento con workflow_name, failed_node, error_type http_5xx y retryable yes'
}
# ---- 13 ------------------------------------------------------------------------------------------------------
if (Want 13) {
    Start-Step 13 'Tests de Django y smoke de la API'
    Clear-Screen
    Show-Cmd 'docker compose exec -T api python manage.py test --noinput'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    # Solo se quita la linea "RemoteException" que PowerShell 5.1 inventa al capturar el stderr de Docker; se muestran las
    # ultimas 5 lineas (lo demas son avisos de log de la propia aplicacion). El resultado (Ran N tests / OK) se muestra completo.
    docker compose exec -T api python manage.py test --noinput 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch 'RemoteException' } | Select-Object -Last 5
    Show-Cmd '.\scripts\smoke-api.ps1'
    & (Join-Path $PSScriptRoot 'smoke-api.ps1') 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 12
    $ErrorActionPreference = $prev
    Wait-Capture '13-tests.png' 'Ran 84 tests ... OK y "14 correctas, 0 fallidas" del smoke'
}

Write-Host ''
Write-Host ('=' * 78)
$done = @(Get-ChildItem -LiteralPath $outDir -Filter '*.png' -ErrorAction SilentlyContinue)
Write-Host ("Capturas en docs\screenshots: {0} de 13" -f $done.Count) -ForegroundColor Green
$done | Sort-Object Name | ForEach-Object { Write-Host ("  {0}  ({1:N0} KB)" -f $_.Name, ($_.Length / 1KB)) }
Write-Host 'Revisa cada imagen antes de subirla: no deben verse tokens, claves, el .env ni datos personales reales.'
