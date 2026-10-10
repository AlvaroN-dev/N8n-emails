<#
.SYNOPSIS
    Pruebas de integracion de WF3 (Error monitoring): como se registran, clasifican y sanean los fallos REALES de WF1 y WF2.

.DESCRIPTION
    Cada caso provoca un fallo real (500 inyectado, SMTP sin responder, entrada invalida, ticket inexistente, Django
    caido...) y comprueba el evento guardado en Django (workflow, etapa, tipo, reintento, ticket, ids de ejecucion),
    que el fallo coincide con la ejecucion real de n8n y que no se filtran datos personales.
    Los casos son inmunes a restos de ejecuciones anteriores: solo cuentan eventos de ejecuciones POSTERIORES a la marca
    de cada caso, y cada caso espera a que WF3 termine antes de pasar al siguiente.
    El caso de "Django caido + SMTP sin responder" tarda ~1,5 min: usar -SkipDoubleFailure para omitirlo.
    Deja tickets y eventos de prueba en la base de datos local.

.EXAMPLE
    .\tests\integration\wf03-errors.ps1
#>
[CmdletBinding()]
param([switch]$SkipDoubleFailure)

. "$PSScriptRoot\lib.ps1"

$stamp = Get-Date -Format 'HHmmss'
$WF1 = 'wfTicketIntake01'
$WF2 = 'wfAiTriageNotify'
$WF3 = 'wfErrorMonitor03'
$PII_EMAIL = "wf3.privado.$stamp@example.com"
$PII_PHONE = '+34 612 345 678'
$PII_MESSAGE = "No puedo pagar mi factura. Mi correo es $PII_EMAIL y mi telefono es $PII_PHONE. Necesito ayuda."

function Submit-Case([string]$Id, [string]$Message = $PII_MESSAGE) {
    $r = Send-Ticket (New-Ticket $Id @{ subject = 'Fallo de prueba WF3'; message = $Message; customer_email = $PII_EMAIL })
    $tid = $null
    if ($r.Json) { $tid = $r.Json.ticket_id }
    return [pscustomobject]@{ Id = $Id; Response = $r; TicketId = $tid }
}
function First-Of($list) { $a = @($list); if ($a.Count -ge 1) { return $a[0] } return $null }

# Solo eventos NUEVOS: cuya ejecucion de n8n es posterior a $AfterId. Asi las pruebas no se contaminan con eventos de
# ejecuciones anteriores que sigan en la base de datos.
function Get-NewEvents([string]$Query, [long]$AfterId) {
    return @(Get-ErrorEvents $Query | Where-Object { ($_.execution_id -match '^[0-9]+$') -and ([long]$_.execution_id -gt $AfterId) })
}
function Wait-NewEvents([string]$Query, [long]$AfterId, [int]$Count = 1, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $events = @(Get-NewEvents $Query $AfterId)
        if ($events.Count -ge $Count -or (Get-Date) -gt $deadline) { return $events }
        Start-Sleep -Seconds 1
    }
}
function Get-Wf3Runs([long]$AfterId) { return @(Get-N8nExecutions -AfterId $AfterId -Workflow $WF3) }

Write-Host "== WF3 - Error monitoring: pruebas de integracion ($stamp)"
foreach ($s in 'api', 'n8n', 'postgres', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
Wait-WorkflowsReady
Clear-Mailpit

try {
    # ================================================================== E1 fallo gestionado de WF1 (Django responde 500)
    $mark = Get-LastExecutionId
    $c = Submit-Case "QA-500-$stamp"
    $ev = @(Wait-NewEvents "ticket_external_id=$($c.Id)" $mark 1 30)
    $w1 = First-Of (Wait-Executions $mark $WF1 1)
    $w3 = @(Wait-Executions $mark $WF3 1)
    Assert-That 'E1' 'el cliente recibe 502 y se registra UN evento del fallo' ($c.Response.Status -eq 502 -and $ev.Count -eq 1) "http=$($c.Response.Status) eventos=$($ev.Count)"
    if ($ev.Count -ge 1) {
        $e = $ev[0]
        Assert-That 'E1' 'el evento dice QUE workflow, EN QUE etapa y de QUE tipo, y si reintentar' ($e.workflow_id -eq $WF1 -and $e.workflow_name -eq '01 - Ticket intake' -and $e.failed_node -eq 'Create ticket in Django' -and $e.error_type -eq 'http_5xx' -and $e.retryable -eq 'yes' -and $e.message -eq 'HTTP 500') ($e | ConvertTo-Json -Compress)
        Assert-That 'E1' 'el execution_id del evento es el de la ejecucion REAL de n8n (trazabilidad)' ($w1 -and [string]$w1.id -eq $e.execution_id) "evento=$($e.execution_id) n8n=$($w1.id)"
    }
    Assert-That 'E1' 'WF3 se ejecuta UNA vez, en success, por el camino Error Trigger > Describe > Register (sin alerta)' ($w3.Count -eq 1 -and $w3[0].status -eq 'success' -and ($w3[0].nodesRun -join '>') -eq 'Error Trigger>Describe failure>Register event in Django') ($w3 | ConvertTo-Json -Compress)
    Assert-That 'E1' 'NO se envia correo de alerta cuando el registro funciona' ((@(Get-AlertMails)).Count -eq 0) ''

    # ================================================================== E2 SMTP sin responder (WF2): fallo gestionado + reproceso guiado por el evento
    $mark = Get-LastExecutionId
    Invoke-Compose @('pause', 'mailpit')
    try {
        $c = Submit-Case "WF3-$stamp-smtp"
        $ev = @(Wait-NewEvents "ticket_external_id=$($c.Id)" $mark 1 80)
    }
    finally {
        Invoke-Compose @('unpause', 'mailpit')
        Wait-ServiceHealthy 'mailpit'
    }
    $e = First-Of $ev
    Assert-That 'E2' 'el fallo del correo se registra: WF2, etapa Send notification email, smtp, reintento MANUAL' ($e -and $e.workflow_id -eq $WF2 -and $e.failed_node -eq 'Send notification email' -and $e.error_type -eq 'smtp' -and $e.retryable -eq 'manual') ($ev | ConvertTo-Json -Compress)
    Assert-That 'E2' 'el evento incluye el ticket afectado (id y external_id): lo necesario para reprocesarlo' ($e -and $e.ticket_id -eq [int]$c.TicketId -and $e.ticket_external_id -eq $c.Id) ($e | ConvertTo-Json -Compress)
    Assert-That 'E2' 'tambien se encuentra filtrando por ticket_id' ((@(Get-ErrorEvents "ticket_id=$($c.TicketId)")).Count -eq 1) ''
    if ($e) { Write-Host ('      mensaje REAL registrado: ' + $e.message) }
    # Siguiendo el consejo del evento (retryable=manual): una persona reprocesa el ticket
    $r = Send-Reprocess $e.ticket_id
    $t = Wait-Ticket -TicketId $e.ticket_id -TimeoutSec 40 -Predicate { param($x) $x.status -eq 'notified' }
    Assert-That 'E2' 'reprocesar el ticket del evento lo completa: notificado y UN solo correo' ($r.Status -eq 202 -and $t.status -eq 'notified' -and (@(Wait-Mail $c.Id 1)).Count -eq 1) ($t | ConvertTo-Json -Compress)

    # ================================================================== E3 error NO gestionado: entrada invalida a WF2 (error crudo de un nodo Code)
    $mark = Get-LastExecutionId
    $null = Send-Reprocess '{"ticket_id": "abc"}'
    $null = Wait-Executions $mark $WF3 1 30
    $ev = @(Wait-NewEvents 'error_type=validation' $mark 1 30)
    $e = First-Of $ev
    Assert-That 'E3' 'un error crudo (sin gestionar) tambien se registra, clasificado por la etapa: validation, no reintentar' ($e -and $e.workflow_id -eq $WF2 -and $e.failed_node -eq 'Validate input' -and $e.error_type -eq 'validation' -and $e.retryable -eq 'no' -and $null -eq $e.ticket_id) ($ev | ConvertTo-Json -Compress)
    Assert-That 'E3' 'el mensaje registrado es corto y no contiene trazas internas' ($e -and $e.message -match '^VALIDATION' -and $e.message.Length -le 500 -and $e.message -notmatch 'at .*\.js|node_modules') ($e | ConvertTo-Json -Compress)

    # ================================================================== E4 ticket inexistente (404 de Django en WF2)
    $mark = Get-LastExecutionId
    $null = Send-Reprocess 999999999
    $ev = @(Wait-NewEvents 'ticket_id=999999999' $mark 1 40)
    $null = Wait-Executions $mark $WF3 1 30   # que WF3 termine antes de pasar al caso siguiente
    $e = First-Of $ev
    Assert-That 'E4' 'ticket inexistente: etapa Get ticket, http_4xx, NO reintentable, con el ticket_id' ($e -and $e.failed_node -eq 'Get ticket' -and $e.error_type -eq 'http_4xx' -and $e.retryable -eq 'no' -and $e.ticket_id -eq 999999999 -and $e.ticket_external_id -eq '') ($ev | ConvertTo-Json -Compress)

    # ================================================================== E5 Django CAIDO: el registro falla -> alerta por correo (no se pierde en silencio)
    Clear-Mailpit
    $mark = Get-LastExecutionId
    $target = [int](Invoke-Sql "select max(id) from tickets_ticket where status = 'notified'")
    Invoke-Compose @('stop', 'api')
    try {
        $null = Send-Reprocess $target
        $alerts = @()
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            $alerts = @(Get-AlertMails)
            if ($alerts.Count -ge 1) { break }
            Start-Sleep -Seconds 3
        }
        $w3 = @(Wait-Executions $mark $WF3 1 30)
    }
    finally {
        Invoke-Compose @('start', 'api')
        Wait-ServiceHealthy 'api'
    }
    Assert-That 'E5' 'con Django caido el fallo NO se pierde: llega un correo de ALERTA' ($alerts.Count -ge 1) "alertas=$($alerts.Count)"
    if ($alerts.Count -ge 1) {
        $a = Get-MailDetail $alerts[0].ID
        $to = @($a.To | ForEach-Object { $_.Address })
        Assert-That 'E5' 'la alerta indica workflow, etapa, tipo y el ticket, y va al destinatario de operaciones' ($to -contains 'ops-alerts@example.test' -and $a.Subject -eq '[ALERT] 02 - AI triage and notification: connection at Get ticket' -and $a.Text -match "Ticket:     #$target " -and $a.Text -match 'could NOT be registered' -and $a.Text -match 'Safe to reprocess') $a.Text
        Assert-That 'E5' 'la alerta NO contiene datos personales (ni correo ni telefono del cliente)' ($a.Text -notmatch [regex]::Escape($PII_EMAIL) -and $a.Text -notmatch '612 345 678') ''
    }
    Assert-That 'E5' 'WF3 se ejecuta UNA vez y acaba en success (envio la alerta); sin bucles' ($w3.Count -eq 1 -and $w3[0].status -eq 'success' -and ($w3[0].nodesRun -contains 'Compose alert email') -and ($w3[0].nodesRun -contains 'Send alert email')) ($w3 | ConvertTo-Json -Compress)
    Assert-That 'E5' 'tras volver Django NO hay evento NUEVO (limitacion conocida: el registro depende de Django; queda la alerta)' ((@(Get-NewEvents "ticket_id=$target" $mark)).Count -eq 0) ''

    # ================================================================== E6 Django vuelve DURANTE los reintentos de WF3
    Clear-Mailpit
    $mark = Get-LastExecutionId
    $target2 = [int](Invoke-Sql "select max(id) from tickets_ticket where status = 'notified' and id <> $target")
    Invoke-Compose @('stop', 'api')
    try {
        $null = Send-Reprocess $target2
        Start-Sleep -Seconds 14   # WF2 agota sus 2 intentos (~12 s) y WF3 empieza a registrar
    }
    finally { Invoke-Compose @('start', 'api') }
    Wait-ServiceHealthy 'api'
    $ev = @(Wait-NewEvents "ticket_id=$target2" $mark 1 60)
    $null = Wait-Executions $mark $WF3 1 60
    Start-Sleep -Seconds 12
    $alertsNow = (@(Get-AlertMails)).Count
    # Segun el momento exacto, o un reintento de WF3 lo registra (sin alerta) o se agotan y llega la alerta: NUNCA ninguna de las dos.
    $recovered = ($ev.Count -eq 1)
    $alerted = ($alertsNow -ge 1)
    Assert-That 'E6' ("el fallo no se pierde: se registro en Django tras volver la API ({0}) o llego una alerta ({1})" -f $ev.Count, $alertsNow) ($recovered -xor $alerted) "eventos=$($ev.Count) alertas=$alertsNow"
    Write-Host ("      resultado observado: eventos={0}, alertas nuevas={1}" -f $ev.Count, $alertsNow)

    # ================================================================== E7 idempotencia del registro (WF3 puede reintentar el POST)
    $payload = @{ workflow_id = $WF2; workflow_name = "prueba-idem-$stamp"; execution_id = "idem-$stamp"; error_type = 'unknown'; retryable = 'manual'; message = 'idempotencia' }
    $a1 = Invoke-Django POST '/api/error-events/' $payload
    $b1 = Invoke-Django POST '/api/error-events/' $payload
    Assert-That 'E7' 'repetir el registro de la misma ejecucion -> 201 y despues 200 duplicate; una sola fila' ($a1.Status -eq 201 -and $b1.Status -eq 200 -and $b1.Json.duplicate -eq $true -and (@(Get-ErrorEvents "workflow_name=prueba-idem-$stamp")).Count -eq 1) "$($a1.Status)/$($b1.Status)"

    # ================================================================== E8 privacidad: ningun evento ni alerta contiene el correo/telefono del cliente
    $all = (Invoke-Django GET '/api/error-events/?limit=200').Raw
    $alertText = ''
    foreach ($m in @(Get-AlertMails)) { $alertText += (Get-MailDetail $m.ID).Text + "`n" }
    Assert-That 'E8' 'ningun evento registrado contiene el correo ni el telefono del cliente de estas pruebas' ($all -notmatch [regex]::Escape($PII_EMAIL) -and $all -notmatch '612 345 678') ''
    Assert-That 'E8' 'ninguna alerta contiene el correo ni el telefono del cliente' ($alertText -notmatch [regex]::Escape($PII_EMAIL) -and $alertText -notmatch '612 345 678') ''

    # ================================================================== E9 doble fallo: Django caido Y SMTP sin responder -> WF3 falla, SIN bucle
    if ($SkipDoubleFailure) { Write-Host 'OMITIDA E9 (-SkipDoubleFailure)' }
    else {
        $mark = Get-LastExecutionId
        $target3 = [int](Invoke-Sql "select max(id) from tickets_ticket where status = 'notified'")
        Invoke-Compose @('stop', 'api')
        Invoke-Compose @('pause', 'mailpit')
        try {
            $null = Send-Reprocess $target3
            $null = Wait-Executions $mark $WF3 1 150
            Start-Sleep -Seconds 20
            $w3 = @(Get-Wf3Runs $mark)
        }
        finally {
            Invoke-Compose @('unpause', 'mailpit')
            Invoke-Compose @('start', 'api')
            Wait-ServiceHealthy 'api'
            Wait-ServiceHealthy 'mailpit'
        }
        Assert-That 'E9' 'cuando WF3 tampoco puede avisar, su propia ejecucion queda en ERROR (visible en n8n) y NO se encadena otra' ($w3.Count -eq 1 -and $w3[0].status -eq 'error' -and $w3[0].lastNode -eq 'Send alert email') ($w3 | ConvertTo-Json -Compress)
    }
}
catch {
    Write-Host "ERROR inesperado en las pruebas: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    try { Invoke-Compose @('unpause', 'mailpit') } catch { }
    foreach ($s in 'api', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { Invoke-Compose @('start', $s) } }
    exit 2
}

$failed = Write-Summary
exit ([int]($failed -gt 0))
