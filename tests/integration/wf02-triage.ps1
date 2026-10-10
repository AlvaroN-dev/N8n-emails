<#
.SYNOPSIS
    Pruebas de integracion de WF2 (IA + correo) con el LLM SIMULADO y Mailpit.

.DESCRIPTION
    Requiere LLM_PROVIDER=mock y QA_TOOLS_ENABLED=true. Todas las pruebas de IA de este script son de IA
    SIMULADA (no prueban un modelo real): comprueban el flujo, la validacion de la salida, el fallback y el
    correo. La prueba con un modelo real esta en wf02-gemini.ps1.
    Un correo se da por entregado solo si aparece en Mailpit (su API HTTP), no por haberse intentado enviar.
    Provoca un fallo real del SMTP PAUSANDO el contenedor de Mailpit (acepta la conexion y no responde: falla siempre a los ~30 s;
    con el contenedor PARADO el resultado depende de la cache ARP de Docker y no es determinista). Deja tickets de prueba en la base de datos.

.PARAMETER SkipSlow
    Omite los casos lentos (timeout del LLM, ~1 min).

.EXAMPLE
    .\tests\integration\wf02-triage.ps1
#>
[CmdletBinding()]
param([switch]$SkipSlow)

. "$PSScriptRoot\lib.ps1"

$stamp = Get-Date -Format 'HHmmss'
$WF1 = 'wfTicketIntake01'
$WF2 = 'wfAiTriageNotify'
$TEAM = 'support-team@example.test'
$BASE_SUBJECT = 'Problema con el pago'
$BASE_MESSAGE = 'No puedo pagar mi factura, me sale un error al pagar. Necesito ayuda.'
$CATEGORIES = @('billing', 'technical', 'account', 'feature_request', 'other')
$PRIORITIES = @('low', 'medium', 'high', 'urgent')

# Envia un ticket por el webhook publico (flujo completo WF1 -> WF2). Devuelve el id de ticket y la respuesta.
function Submit-Case {
    param([string]$Id, [string]$Marker = '', [string]$Message = $BASE_MESSAGE, [string]$Email = 'cliente.prueba@example.com')
    if ($Marker) { $Message = "$Message [[MOCK:$Marker]]" }
    $r = Send-Ticket (New-Ticket $Id @{ subject = $BASE_SUBJECT; message = $Message; customer_email = $Email })
    if ($r.Status -ne 201) { throw "No se acepto el ticket ${Id}: $(Detail $r)" }
    return [pscustomobject]@{ Id = $Id; TicketId = [int]$r.Json.ticket_id }
}
function Wait-Notified([int]$TicketId, [int]$TimeoutSec = 40) {
    return Wait-Ticket -TicketId $TicketId -TimeoutSec $TimeoutSec -Predicate { param($t) $t.status -eq 'notified' }
}
function Get-LatestWf2([long]$AfterId) { return (@(Get-N8nExecutions -AfterId $AfterId -Workflow $WF2) | Select-Object -First 1) }

Write-Host "== WF2 - IA + correo: pruebas de integracion con IA SIMULADA ($stamp)"
foreach ($s in 'api', 'n8n', 'postgres', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
Wait-WorkflowsReady
Clear-Mailpit

try {
    # ============================================================== T01 flujo completo con IA simulada valida
    $mark = Get-LastExecutionId
    $c = Submit-Case "WF2-$stamp-t01"
    $t = Wait-Notified $c.TicketId
    Assert-That 'T01' 'el ticket llega a notified con triage de IA (source=ai) y categoria/prioridad esperadas' ($t.status -eq 'notified' -and $t.triage_source -eq 'ai' -and $t.category -eq 'billing' -and $t.priority -eq 'high' -and $t.triage_reason -eq '' -and $t.notified_at) ($t | ConvertTo-Json -Compress)
    Assert-That 'T01' 'el resumen viene de la IA y es de una sola linea' ($t.summary -like 'Simulated AI summary:*' -and $t.summary -notmatch '[\r\n]') $t.summary
    $mails = @(Wait-Mail $c.Id 1)
    Assert-That 'T01' 'EXACTAMENTE un correo entregado en Mailpit' ($mails.Count -eq 1) "correos=$($mails.Count)"
    if ($mails.Count -ge 1) {
        $m = Get-MailDetail $mails[0].ID
        $to = @($m.To | ForEach-Object { $_.Address })
        Assert-That 'T01' 'destinatario fijo, remitente y asunto con el formato definido' ($to.Count -eq 1 -and $to[0] -eq $TEAM -and $m.From.Address -eq 'triage@tickets.local' -and $m.Subject -eq "[HIGH] Ticket #$($c.TicketId) ($($c.Id)): $BASE_SUBJECT") "to=$($to -join ',') from=$($m.From.Address) subject=$($m.Subject)"
        Assert-That 'T01' 'el cuerpo trae prioridad, categoria, resumen y el metodo (IA validada)' ($m.Text -match 'Priority:  HIGH' -and $m.Text -match 'Category:  billing' -and $m.Text -match 'Simulated AI summary' -and $m.Text -match 'Triage by: AI') $m.Text
    }
    $e = Get-LatestWf2 $mark
    Assert-That 'T01' 'WF2 en success, paso por validacion y NO por el camino de fallo de la IA' ($e -and $e.status -eq 'success' -and ($e.nodesRun -contains 'Validate AI output') -and ($e.nodesRun -contains 'Mark notified') -and -not ($e.nodesRun -contains 'AI call failed')) ($e | ConvertTo-Json -Compress)
    if ($e) { Write-Host ("      nodos de WF2: " + ($e.nodesRun -join ' > ')) }

    # ============================================================== T01b minimizacion de datos hacia el LLM
    $private = 'maria.privada@example.com'
    $msg = "Mi correo es $private y mi telefono es +34 612 345 678. No puedo pagar la factura."
    $c = Submit-Case "WF2-$stamp-t01b" 'ECHO' $msg $private
    $t = Wait-Notified $c.TicketId
    Assert-That 'T01b' 'el LLM recibio el texto con correo y telefono REDACTADOS (el resumen "eco" no los contiene)' ($t.triage_source -eq 'ai' -and $t.summary -notmatch 'maria\.privada' -and $t.summary -notmatch '612 345 678' -and $t.summary -match '\[email\]' -and $t.summary -match '\[phone\]') $t.summary
    $mails = @(Wait-Mail $c.Id 1)
    $body = if ($mails.Count -ge 1) { (Get-MailDetail $mails[0].ID).Text } else { '' }
    Assert-That 'T01b' 'el correo INTERNO al equipo si lleva el cliente (es su cometido); el dato no se perdio, solo no viajo al LLM' ($body -match [regex]::Escape($private)) ''

    # ============================================================== T07 IA devuelve respuesta vacia
    $c = Submit-Case "WF2-$stamp-t07" 'EMPTY'
    $t = Wait-Notified $c.TicketId
    Assert-That 'T07' 'respuesta vacia -> fallback por reglas con motivo ai_empty (no se oculta)' ($t.triage_source -eq 'fallback' -and $t.triage_reason -eq 'ai_empty' -and $t.status -eq 'notified') ($t | ConvertTo-Json -Compress)
    Assert-That 'T07' 'el triage por reglas es completo y valido (categoria y prioridad del contrato)' ($CATEGORIES -contains $t.category -and $PRIORITIES -contains $t.priority -and $t.summary -like 'Rules-based summary:*') ($t | ConvertTo-Json -Compress)
    $mails = @(Wait-Mail $c.Id 1)
    $body = if ($mails.Count -ge 1) { (Get-MailDetail $mails[0].ID).Text } else { '' }
    Assert-That 'T07' 'un unico correo y declara explicitamente el modo degradado y su motivo' ($mails.Count -eq 1 -and $body -match 'RULES FALLBACK \(reason: ai_empty\)') $body

    # ============================================================== T08 salidas invalidas de la IA
    $invalid = @(
        @{ mode = 'NOT_JSON';        reason = 'ai_invalid_json' },
        @{ mode = 'WRAPPED_TEXT';    reason = 'ai_invalid_json' },
        @{ mode = 'BAD_CATEGORY';    reason = 'ai_invalid_category' },
        @{ mode = 'BAD_PRIORITY';    reason = 'ai_invalid_priority' },
        @{ mode = 'MISSING_FIELD';   reason = 'ai_invalid_summary' }
    )
    foreach ($case in $invalid) {
        $c = Submit-Case ("WF2-$stamp-t08-" + $case.mode.ToLower().Replace('_', '')) $case.mode
        $t = Wait-Notified $c.TicketId
        Assert-That 'T08' "$($case.mode) -> fallback con motivo $($case.reason); nunca se usa un valor invalido" ($t.triage_source -eq 'fallback' -and $t.triage_reason -eq $case.reason -and $CATEGORIES -contains $t.category -and $PRIORITIES -contains $t.priority -and $t.category -ne 'banana' -and $t.priority -ne 'critical') ($t | ConvertTo-Json -Compress)
        Assert-That 'T08' "$($case.mode) -> un unico correo entregado" ((@(Wait-Mail $c.Id 1)).Count -eq 1) ''
    }
    # Salidas que SI son aceptables tras la normalizacion
    $c = Submit-Case "WF2-$stamp-t08-fenced" 'FENCED'
    $t = Wait-Notified $c.TicketId
    Assert-That 'T08' 'FENCED (JSON dentro de un bloque ```json) -> aceptado como IA' ($t.triage_source -eq 'ai' -and $t.category -eq 'billing') ($t | ConvertTo-Json -Compress)
    $c = Submit-Case "WF2-$stamp-t08-long" 'LONG_SUMMARY'
    $t = Wait-Notified $c.TicketId
    Assert-That 'T08' 'LONG_SUMMARY (600 caracteres) -> aceptado y recortado a 280' ($t.triage_source -eq 'ai' -and $t.summary.Length -eq 280 -and $t.summary.EndsWith('...')) "len=$($t.summary.Length)"
    $c = Submit-Case "WF2-$stamp-t08-newlines" 'NEWLINES'
    $t = Wait-Notified $c.TicketId
    Assert-That 'T08' 'NEWLINES (saltos de linea y caracter de control) -> aplanado a una linea' ($t.triage_source -eq 'ai' -and $t.summary -eq 'Line one Line two Tabbed and bell') $t.summary

    # ============================================================== T08b prompt injection / la IA no controla operaciones
    $c = Submit-Case "WF2-$stamp-t08-inject" 'INJECTION'
    $t = Wait-Notified $c.TicketId
    $mails = @(Wait-Mail $c.Id 1)
    $all = Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/messages?limit=500"
    $toAll = @($all.messages | ForEach-Object { $_.To | ForEach-Object { $_.Address } })
    $m = if ($mails.Count -ge 1) { Get-MailDetail $mails[0].ID } else { $null }
    Assert-That 'T08b' 'la IA devolvio instrucciones maliciosas y claves extra: el resumen se guarda COMO TEXTO' ($t.triage_source -eq 'ai' -and $t.summary -match 'IGNORE ALL PREVIOUS INSTRUCTIONS') $t.summary
    Assert-That 'T08b' 'NINGUN correo salio hacia attacker@evil.test; el unico destinatario es el del equipo' ($mails.Count -eq 1 -and @($toAll | Where-Object { $_ -like '*attacker*' }).Count -eq 0 -and @($m.To).Count -eq 1 -and $m.To[0].Address -eq $TEAM) "destinatarios globales: $($toAll | Sort-Object -Unique)"
    Assert-That 'T08b' 'el ticket sigue siendo consistente: no se borro nada (la clave "action" del modelo se ignoro)' ((Invoke-Django GET "/api/tickets/$($c.TicketId)/").Status -eq 200) ''

    # ============================================================== T09 errores del proveedor de IA
    $cases = @(
        @{ mode = 'HTTP429'; reason = 'ai_rate_limited' },
        @{ mode = 'HTTP500'; reason = 'ai_provider_error' }
    )
    foreach ($case in $cases) {
        $before = Get-ApiLogCount "llm_mock mode=$($case.mode)"
        $c = Submit-Case ("WF2-$stamp-t09-" + $case.mode.ToLower()) $case.mode
        $t = Wait-Notified $c.TicketId
        $calls = (Get-ApiLogCount "llm_mock mode=$($case.mode)") - $before
        Assert-That 'T09' "$($case.mode) -> fallback con motivo $($case.reason), ticket notificado" ($t.triage_source -eq 'fallback' -and $t.triage_reason -eq $case.reason -and $t.status -eq 'notified') ($t | ConvertTo-Json -Compress)
        Assert-That 'T09' "$($case.mode) -> sin tormenta de reintentos (llamadas al proveedor: $calls, maximo 2)" ($calls -ge 1 -and $calls -le 2) "llamadas=$calls"
        Assert-That 'T09' "$($case.mode) -> un unico correo" ((@(Wait-Mail $c.Id 1)).Count -eq 1) ''
    }
    if ($SkipSlow) { Write-Host 'OMITIDA T09 SLOW (-SkipSlow)' }
    else {
        $before = Get-ApiLogCount 'llm_mock mode=SLOW'
        $mark = Get-LastExecutionId
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $c = Submit-Case "WF2-$stamp-t09-slow" 'SLOW'
        $t = Wait-Notified $c.TicketId 120
        $sw.Stop()
        $calls = (Get-ApiLogCount 'llm_mock mode=SLOW') - $before
        $e = Get-LatestWf2 $mark
        Assert-That 'T09' ('SLOW -> timeout del LLM (20 s): fallback ai_timeout; WF2 acaba en {0:N0} s, dentro del limite de 90 s' -f $sw.Elapsed.TotalSeconds) ($t.triage_source -eq 'fallback' -and $t.triage_reason -eq 'ai_timeout' -and $t.status -eq 'notified' -and $sw.Elapsed.TotalSeconds -lt 90) ($t | ConvertTo-Json -Compress)
        Assert-That 'T09' "SLOW -> sin tormenta de reintentos (llamadas: $calls, maximo 2) y WF2 en success" ($calls -ge 1 -and $calls -le 2 -and $e.status -eq 'success') "llamadas=$calls"
    }

    # ============================================================== T11 / T13 fallo del servicio de correo y reproceso
    $mark = Get-LastExecutionId
    Invoke-Compose @('pause', 'mailpit')   # pausado: acepta la conexion pero no saluda -> fallo DETERMINISTA (~30 s)
    $failExec = $null; $c = $null
    try {
        $c = Submit-Case "WF2-$stamp-t11"
        $failExec = @(Wait-Executions $mark $WF2 1 60)[0]
        $t = Wait-Ticket -TicketId $c.TicketId -TimeoutSec 20 -Predicate { param($x) $x.triaged_at }
    }
    finally {
        Invoke-Compose @('unpause', 'mailpit')
        Wait-ServiceHealthy 'mailpit'
    }
    $ff = if ($failExec) { ConvertFrom-HandledFailure $failExec.error } else { $null }
    Assert-That 'T11' 'con el SMTP sin responder, WF2 acaba en ERROR gestionado: type=smtp retryable=manual (no se oculta)' ($failExec -and $failExec.status -eq 'error' -and $failExec.error -match '^HANDLED_FAILURE type=smtp retryable=manual data=') ($failExec | ConvertTo-Json -Compress)
    Assert-That 'T11' 'el fallo identifica la etapa y el TICKET afectado (para poder reprocesarlo)' ($ff -and $ff.node -eq 'Send notification email' -and $ff.ticket_id -eq $c.TicketId -and $ff.ticket_external_id -eq $c.Id) ($ff | ConvertTo-Json -Compress)
    if ($ff) { Write-Host ("      detalle real del fallo de envio: " + $ff.detail) }
    Assert-That 'T11' 'el triage SI se guardo, pero el ticket NO esta notificado' ($t.triaged_at -and $t.status -eq 'triaged' -and -not $t.notified_at -and $t.triage_source -eq 'ai') ($t | ConvertTo-Json -Compress)
    Start-Sleep -Seconds 12
    Assert-That 'T11' 'sin reintento automatico del correo: tras volver el SMTP no aparece ningun correo por si solo' ((@(Get-MailFor $c.Id)).Count -eq 0) ''

    # T13: reproceso manual tras restaurar el servicio
    $llmBefore = Get-ApiLogCount 'llm_mock mode='
    $mark2 = Get-LastExecutionId
    $r = Send-Reprocess $c.TicketId
    Assert-That 'T13' 'el webhook interno acepta el reproceso (202)' ($r.Status -eq 202) (Detail $r)
    $t = Wait-Notified $c.TicketId
    $mails = @(Wait-Mail $c.Id 1)
    $e2 = Get-LatestWf2 $mark2
    Assert-That 'T13' 'tras el reproceso el ticket queda notificado y hay UN solo correo' ($t.status -eq 'notified' -and $mails.Count -eq 1) "correos=$($mails.Count)"
    Assert-That 'T13' 'el reproceso REUTILIZA el triage guardado: no vuelve a llamar a la IA' ((Get-ApiLogCount 'llm_mock mode=') -eq $llmBefore -and $e2.status -eq 'success' -and -not ($e2.nodesRun -contains 'Prepare AI input') -and ($e2.nodesRun -contains 'Compose email')) ($e2 | ConvertTo-Json -Compress)

    # Reprocesar un ticket YA notificado no envia otro correo (guardia de idempotencia)
    $mark3 = Get-LastExecutionId
    $null = Send-Reprocess $c.TicketId
    $e3 = @(Wait-Executions $mark3 $WF2 1)[0]
    Start-Sleep -Seconds 3
    Assert-That 'T13' 'reprocesar un ticket ya notificado termina en la guardia y NO envia un segundo correo' ($e3.status -eq 'success' -and ($e3.nodesRun -contains 'Skip - already notified') -and -not ($e3.nodesRun -contains 'Send notification email') -and (@(Get-MailFor $c.Id)).Count -eq 1) ($e3 | ConvertTo-Json -Compress)

    # ============================================================== T12 entradas invalidas al webhook interno
    $mark = Get-LastExecutionId
    $r = Send-Reprocess '{"ticket_id": "abc"}'
    Assert-That 'T12' 'ticket_id invalido: el webhook responde 202 (ya acepto) pero la ejecucion FALLA en Validate input' ($r.Status -eq 202) (Detail $r)
    $e = @(Wait-Executions $mark $WF2 1)[0]
    Assert-That 'T12' 'la ejecucion queda en error con mensaje VALIDATION y nadie recibe correo' ($e.status -eq 'error' -and $e.lastNode -eq 'Validate input' -and $e.error -match 'VALIDATION') ($e | ConvertTo-Json -Compress)
    $mark = Get-LastExecutionId
    $null = Send-Reprocess 999999999
    $e = @(Wait-Executions $mark $WF2 1 40)[0]
    $ff = if ($e) { ConvertFrom-HandledFailure $e.error } else { $null }
    Assert-That 'T12' 'ticket inexistente: fallo GESTIONADO en la etapa Get ticket (404 de Django): http_4xx, no reintentable, con el ticket_id' ($e.status -eq 'error' -and $ff -and $ff.node -eq 'Get ticket' -and $ff.type -eq 'http_4xx' -and $ff.retryable -eq 'no' -and $ff.ticket_id -eq 999999999) ($e | ConvertTo-Json -Compress)
    if ($ff) { Write-Host ("      detalle real del 404: " + $ff.detail) }
}
catch {
    Write-Host "ERROR inesperado en las pruebas: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    try { Invoke-Compose @('unpause', 'mailpit') } catch { }
    foreach ($s in 'mailpit', 'api') { if ((Get-ServiceHealth $s) -ne 'healthy') { Invoke-Compose @('start', $s) } }
    exit 2
}

$failed = Write-Summary
exit ([int]($failed -gt 0))
