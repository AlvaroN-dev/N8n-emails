# Biblioteca comun de las pruebas de integracion (se carga con:  . "$PSScriptRoot\lib.ps1").
# Compatible con Windows PowerShell 5.1 y PowerShell 7. Solo ASCII.
$ErrorActionPreference = 'Stop'
$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $script:Root

# ---- .env ----------------------------------------------------------------------------
$script:EnvVars = @{}
# TT_ENV_FILE permite apuntar a otro entorno (p. ej. el proyecto desechable de la prueba de instalacion limpia).
$script:EnvFileName = if ($env:TT_ENV_FILE) { $env:TT_ENV_FILE } else { '.env' }
foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $script:Root $script:EnvFileName))) {
    if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') { $script:EnvVars[$Matches[1]] = $Matches[2].Trim() }
}
function Get-EnvValue([string]$Name) {
    if (-not $script:EnvVars.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($script:EnvVars[$Name])) {
        throw "Falta $Name en .env"
    }
    return $script:EnvVars[$Name]
}

# ---- HTTP -----------------------------------------------------------------------------
# Devuelve Status (0 = sin respuesta), Json, Raw y Error. NO lanza excepcion con 4xx/5xx.
function Invoke-Http {
    param(
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [string]$Body = $null,
        [string]$ContentType = 'application/json',
        [int]$TimeoutSec = 60
    )
    $params = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    # Un parametro [string] con $null llega como '': se comprueba vacio, no $null (un GET no admite cuerpo).
    if (-not [string]::IsNullOrEmpty($Body)) { $params.Body = $Body; $params.ContentType = $ContentType }
    $status = 0; $content = ''; $err = $null
    try {
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode
        $content = $r.Content
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { $err = $_.Exception.Message }
        else {
            $status = [int]$resp.StatusCode
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
            else {
                try { $reader = New-Object System.IO.StreamReader($resp.GetResponseStream()); $content = $reader.ReadToEnd(); $reader.Dispose() } catch { $content = '' }
            }
        }
    }
    $json = $null
    if ($content) { try { $json = $content | ConvertFrom-Json } catch { $json = $null } }
    return [pscustomobject]@{ Status = $status; Json = $json; Raw = $content; Error = $err }
}

function Invoke-Django {
    param([string]$Method, [string]$Path, $Body = $null)
    $json = $null
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Compress) }
    return Invoke-Http -Method $Method -Url "http://127.0.0.1:$(Get-Port 'API_HOST_PORT' 8000)$Path" `
        -Headers @{ 'X-API-Key' = (Get-EnvValue 'DJANGO_API_KEY') } -Body $json
}

function Get-Port([string]$Name, [int]$Default) {
    if ($script:EnvVars.ContainsKey($Name) -and $script:EnvVars[$Name]) { return [int]$script:EnvVars[$Name] }
    return $Default
}

# ---- Docker / servicios -----------------------------------------------------------------
function Get-ServiceHealth([string]$Service) {
    return ((& docker compose ps $Service --format '{{.Health}}') -join '').Trim()
}
function Wait-ServiceHealthy {
    param([string]$Service, [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ServiceHealth $Service) -eq 'healthy') { return }
        Start-Sleep -Seconds 2
    }
    throw "El servicio $Service no llego a healthy en $TimeoutSec s"
}

# Consulta SQL de solo lectura contra la base de datos de la API.
function Invoke-Sql([string]$Sql) {
    $user = if ($script:EnvVars['POSTGRES_USER']) { $script:EnvVars['POSTGRES_USER'] } else { 'tickets' }
    $db   = if ($script:EnvVars['POSTGRES_DB']) { $script:EnvVars['POSTGRES_DB'] } else { 'tickets' }
    $out = & docker compose exec -T postgres psql -U $user -d $db -tAc $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql fallo: $Sql" }
    return (($out -join "`n").Trim())
}
function Get-TicketCount([string]$ExternalIdPrefix = '') {
    return [int](Invoke-Sql "select count(*) from tickets_ticket where external_id like '$ExternalIdPrefix%'")
}

# ---- Ejecuciones de n8n (lectura de su SQLite, ver n8n/src/tools/executions.js) ----------
function Get-N8nExecutions {
    param([long]$AfterId = 0, [string]$Workflow = '', [int]$Limit = 50)
    $cmd = @('exec', '-T', 'n8n', 'node', '--no-warnings', '/import/src/tools/executions.js', '--after-id', "$AfterId", '--limit', "$Limit")
    if ($Workflow) { $cmd += @('--workflow', $Workflow) }
    $text = (& docker compose @cmd | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer el historial de ejecuciones de n8n' }
    $parsed = $text | ConvertFrom-Json
    $list = @()
    foreach ($x in $parsed) { if ($null -ne $x) { $list += $x } }
    # Idioma estandar: se devuelve el array normal; QUIEN LLAMA debe envolver con @(...) para que .Count sea fiable.
    return $list
}
function Get-LastExecutionId {
    $rows = @(Get-N8nExecutions -Limit 1)
    if ($rows.Count -eq 0) { return 0 }
    return [long]$rows[0].id
}
# Decodifica el mensaje HANDLED_FAILURE (ver encodeFailure en n8n/src/snippets/shared.js) a un objeto.
function ConvertFrom-HandledFailure([string]$Message) {
    if ($Message -notmatch 'data=([0-9a-f]+)') { return $null }
    $hex = $Matches[1]
    if ($hex.Length % 2 -ne 0) { return $null }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $hex.Length; $i += 2) { [void]$sb.Append([char][Convert]::ToInt32($hex.Substring($i, 2), 16)) }
    try { return ($sb.ToString() | ConvertFrom-Json) } catch { return $null }
}
# Espera a que existan al menos $Count ejecuciones TERMINADAS (success/error) de $Workflow posteriores a $AfterId.
function Wait-Executions {
    param([long]$AfterId, [string]$Workflow, [int]$Count = 1, [int]$TimeoutSec = 25)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = @()
    while ($true) {
        $rows = @(Get-N8nExecutions -AfterId $AfterId -Workflow $Workflow)
        $done = @($rows | Where-Object { $_.status -notin @('running', 'new', 'waiting') })
        if ($done.Count -ge $Count -or (Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 1
    }
    return $done
}
# Cuantas ejecuciones (de cualquier estado) de $Workflow hay tras $AfterId, esperando un instante a que aparezcan.
function Count-Executions {
    param([long]$AfterId, [string]$Workflow, [int]$SettleSeconds = 4)
    Start-Sleep -Seconds $SettleSeconds
    return @(Get-N8nExecutions -AfterId $AfterId -Workflow $Workflow).Count
}

# ---- Resultados -------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
function Assert-That {
    param([string]$Id, [string]$Description, [bool]$Condition, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Id = $Id; Description = $Description; Passed = $Condition })
    if ($Condition) { Write-Host ("PASS  {0,-5} {1}" -f $Id, $Description) }
    else { Write-Host ("FAIL  {0,-5} {1}  [{2}]" -f $Id, $Description, $Detail) -ForegroundColor Red }
}
function Write-Summary {
    $failed = @($script:Results | Where-Object { -not $_.Passed }).Count
    $total = $script:Results.Count
    Write-Host ("== Resultado: {0} comprobaciones, {1} correctas, {2} fallidas" -f $total, ($total - $failed), $failed)
    return $failed
}

# ---- docker compose con salida de progreso en stderr -------------------------------------
# docker compose escribe su progreso en stderr. En Windows PowerShell 5.1, con 'Stop', eso se convierte en un error
# terminante aunque el comando vaya bien (p. ej. si quien llama redirige 2>&1) y podria dejar un servicio parado.
# El exito se decide SOLO por el codigo de salida.
function Invoke-Compose {
    param([string[]]$ComposeArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose @ComposeArgs 2>&1 | ForEach-Object { "$_" } | Out-Host }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') termino con codigo $LASTEXITCODE" }
}

# ---- Envio de tickets (webhook publico) y reproceso (webhook interno) ----------------------------------------
$script:N8nPort = Get-Port 'N8N_HOST_PORT' 5678
$script:WebhookUrl = "http://127.0.0.1:$($script:N8nPort)/webhook/tickets"
$script:InternalWebhookUrl = "http://127.0.0.1:$($script:N8nPort)/webhook/internal/ticket-triage"
$script:IntakeToken = Get-EnvValue 'INTAKE_WEBHOOK_TOKEN'
$script:InternalToken = Get-EnvValue 'INTERNAL_WEBHOOK_TOKEN'

function New-Ticket([string]$Id, [hashtable]$Override = @{}) {
    $t = [ordered]@{
        external_id    = $Id
        customer_email = 'ana.test@example.com'
        subject        = 'No puedo iniciar sesion'
        message        = 'No puedo iniciar sesion desde esta manana, por favor ayuda con mi cuenta.'
        source         = 'web'
    }
    foreach ($k in $Override.Keys) { $t[$k] = $Override[$k] }
    return $t
}
function Send-Ticket($Body, [string]$Token = $script:IntakeToken, [int]$TimeoutSec = 60) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress }
    $headers = @{}
    if ($Token) { $headers['X-Webhook-Token'] = $Token }
    return Invoke-Http -Method POST -Url $script:WebhookUrl -Headers $headers -Body $json -TimeoutSec $TimeoutSec
}
# Reprocesa un ticket llamando al webhook INTERNO de WF2 (responde 202 enseguida y trabaja en segundo plano).
function Send-Reprocess($TicketId, [string]$Token = $script:InternalToken) {
    $json = if ($TicketId -is [string]) { $TicketId } else { (@{ ticket_id = $TicketId } | ConvertTo-Json -Compress) }
    $headers = @{}
    if ($Token) { $headers['X-Webhook-Token'] = $Token }
    return Invoke-Http -Method POST -Url $script:InternalWebhookUrl -Headers $headers -Body $json
}
function Detail($r) { return "HTTP $($r.Status) $($r.Raw) $($r.Error)" }

# ---- Mailpit (SMTP de pruebas): la prueba de que un correo SE ENTREGO, no solo de que se intento ----------------
$script:MailpitUrl = "http://127.0.0.1:$(Get-Port 'MAILPIT_HOST_PORT' 8025)"
function Clear-Mailpit { Invoke-RestMethod -Method Delete -Uri "$($script:MailpitUrl)/api/v1/messages" | Out-Null }
# Correos cuyo asunto contiene "(<external_id>)" (formato del asunto que genera WF2).
function Get-MailFor([string]$ExternalId) {
    $r = Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/messages?limit=200"
    return @($r.messages | Where-Object { $_.Subject -like "*($ExternalId)*" })
}
function Get-MailDetail([string]$MailId) { return Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/message/$MailId" }
function Wait-Mail {
    param([string]$ExternalId, [int]$Count = 1, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $mails = @()
    while ($true) {
        $mails = @(Get-MailFor $ExternalId)
        if ($mails.Count -ge $Count -or (Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 1
    }
    return $mails
}

# ---- Estado del ticket en Django ----------------------------------------------------------------------------------
# Espera a que el ticket cumpla $Predicate (scriptblock sobre el ticket). Devuelve el ultimo estado leido.
function Wait-Ticket {
    param([int]$TicketId, [scriptblock]$Predicate, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ticket = $null
    while ($true) {
        $r = Invoke-Django GET "/api/tickets/$TicketId/"
        if ($r.Status -eq 200) { $ticket = $r.Json; if (& $Predicate $ticket) { break } }
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 1
    }
    return $ticket
}

# Cuantas lineas del log de la API contienen $Pattern (para contar llamadas al LLM simulado).
function Get-ApiLogCount([string]$Pattern) {
    $text = (& docker compose logs api --no-color | Out-String)
    return ([regex]::Matches($text, $Pattern)).Count
}

# ---- Version de los workflows realmente en marcha ----------------------------------------------------------------
# "healthy" no basta: tras reiniciar, n8n sirve la version ANTERIOR unos segundos (ver n8n/src/tools/published.js).
function Wait-WorkflowsReady {
    param([string[]]$Ids = @('wfTicketIntake01', 'wfAiTriageNotify', 'wfErrorMonitor03'), [int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $state = ''
    while ($true) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $state = (& docker compose exec -T n8n node --no-warnings /import/src/tools/published.js @($Ids) 2>&1 | Out-String).Trim() }
        finally { $ErrorActionPreference = $previous }
        if ($LASTEXITCODE -eq 0) { return }
        if ((Get-Date) -gt $deadline) { throw "Los workflows no estan en marcha tras $TimeoutSec s: $state" }
        Start-Sleep -Seconds 2
    }
}

# ---- Eventos de error registrados por WF3 en Django -----------------------------------------------------------
# $Query: parametros de filtro, p. ej. 'ticket_external_id=ABC' o 'ticket_id=7'. Devuelve la lista (puede estar vacia).
function Get-ErrorEvents([string]$Query = '') {
    $path = '/api/error-events/?limit=200'
    if ($Query) { $path = "$path&$Query" }
    $r = Invoke-Django GET $path
    if ($r.Status -ne 200) { throw "No se pudo leer error-events: $(Detail $r)" }
    return @($r.Json.results)
}
function Wait-ErrorEvents {
    param([string]$Query, [int]$Count = 1, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $events = @()
    while ($true) {
        $events = @(Get-ErrorEvents $Query)
        if ($events.Count -ge $Count -or (Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 1
    }
    return $events
}
# Correos de ALERTA de WF3 (se envian cuando el fallo no pudo registrarse en Django): asunto "[ALERT] ...".
function Get-AlertMails {
    $r = Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/messages?limit=200"
    return @($r.messages | Where-Object { $_.Subject.StartsWith('[ALERT]') })
}
