<#
.SYNOPSIS
    Pruebas de integracion de WF1 (Ticket intake) contra el webhook REAL de n8n.

.DESCRIPTION
    Cada caso comprueba (1) la respuesta HTTP, (2) el estado real en Django y (3) lo ocurrido dentro de
    n8n: estado de la ejecucion y nodos recorridos. Provoca fallos reales parando contenedores y usando
    los prefijos de QA (QA-500-*, QA-SLOW-*), por lo que necesita QA_TOOLS_ENABLED=true.
    Deja tickets de prueba en la base de datos local.

.PARAMETER SkipSlowRecovery
    Omite T06b (espera ~2 minutos a que un ticket atascado sea reprocesable).

.EXAMPLE
    .\tests\integration\wf01-intake.ps1
#>
[CmdletBinding()]
param([switch]$SkipSlowRecovery)

. "$PSScriptRoot\lib.ps1"

$webhook  = "http://127.0.0.1:$(Get-Port 'N8N_HOST_PORT' 5678)/webhook/tickets"
$internal = "http://127.0.0.1:$(Get-Port 'N8N_HOST_PORT' 5678)/webhook/internal/ticket-triage"
$intakeToken   = Get-EnvValue 'INTAKE_WEBHOOK_TOKEN'
$internalToken = Get-EnvValue 'INTERNAL_WEBHOOK_TOKEN'
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$WF1 = 'wfTicketIntake01'
$WF2 = 'wfAiTriageNotify'


Write-Host "== WF1 - Ticket intake: pruebas de integracion ($stamp)"
Write-Host '== Estado previo: servicios healthy'
foreach ($s in 'api', 'n8n', 'postgres') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
Wait-WorkflowsReady

try {
    # ---------------------------------------------------------------- T01 solicitud valida
    $mark = Get-LastExecutionId
    $t = New-Ticket "WF1-$stamp-t01"
    $r = Send-Ticket $t
    Assert-That 'T01' 'HTTP 201 accepted con ticket_id y external_id' ($r.Status -eq 201 -and $r.Json.status -eq 'accepted' -and $r.Json.ticket_id -gt 0 -and $r.Json.external_id -eq $t.external_id) (Detail $r)
    $tk = Invoke-Django GET "/api/tickets/$($r.Json.ticket_id)/"
    Assert-That 'T01' 'el ticket existe en Django con los datos enviados' ($tk.Status -eq 200 -and $tk.Json.external_id -eq $t.external_id -and $tk.Json.subject -eq $t.subject -and $tk.Json.customer_email -eq $t.customer_email) (Detail $tk)
    $e1 = @(Wait-Executions $mark $WF1 1)
    $e2 = @(Wait-Executions $mark $WF2 1)
    Assert-That 'T01' 'WF1 termina en success y pasa por Create ticket + Start triage' ($e1.Count -eq 1 -and $e1[0].status -eq 'success' -and ($e1[0].nodesRun -contains 'Create ticket in Django') -and ($e1[0].nodesRun -contains 'Start triage (WF2)')) ($e1 | ConvertTo-Json -Compress)
    Assert-That 'T01' 'WF2 se lanza exactamente una vez' ($e2.Count -eq 1 -and $e2[0].status -eq 'success') ($e2 | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- T00 calibracion del contador de ejecuciones
    # Un contador que siempre devuelve lo mismo daria falsos aciertos en los casos "no se lanza WF2": debe poder
    # ver ejecuciones donde las hay (>=1) y NO verlas donde no las hay (=0).
    $lastNow = Get-LastExecutionId
    Assert-That 'T00' 'calibracion: el contador ve >=1 ejecucion de WF1 y WF2 tras T01, y 0 despues de la ultima' ((Count-Executions $mark $WF1 1) -ge 1 -and (Count-Executions $mark $WF2 0) -ge 1 -and (Count-Executions $lastNow $WF1 0) -eq 0 -and (Count-Executions $lastNow $WF2 0) -eq 0) ''

    # ---------------------------------------------------------------- T02 campos obligatorios ausentes
    $mark = Get-LastExecutionId; $before = Get-TicketCount
    $r = Send-Ticket '{}'
    $fields = if ($r.Json -and $r.Json.details) { @($r.Json.details.PSObject.Properties.Name | Sort-Object) } else { @() }
    Assert-That 'T02' 'HTTP 400 validation_error con un detalle por cada campo obligatorio' ($r.Status -eq 400 -and $r.Json.code -eq 'validation_error' -and (($fields -join ',') -eq 'customer_email,external_id,message,subject')) (Detail $r)
    $e1 = @(Wait-Executions $mark $WF1 1)
    Assert-That 'T02' 'WF1 NO llega a Django ni lanza WF2; la ejecucion no es un fallo' ($e1.Count -eq 1 -and $e1[0].status -eq 'success' -and -not ($e1[0].nodesRun -contains 'Create ticket in Django') -and (Count-Executions $mark $WF2 2) -eq 0) ($e1 | ConvertTo-Json -Compress)
    Assert-That 'T02' 'no se crea ningun ticket' ((Get-TicketCount) -eq $before) "antes=$before ahora=$(Get-TicketCount)"

    # ---------------------------------------------------------------- T03 tipos incorrectos
    $before = Get-TicketCount
    $cases = @(
        @{ field = 'subject';        value = 12345 },
        @{ field = 'message';        value = @('a', 'b') },
        @{ field = 'external_id';    value = 1001 },
        @{ field = 'customer_email'; value = 123 },
        @{ field = 'source';         value = 7 }
    )
    foreach ($c in $cases) {
        $body = New-Ticket "WF1-$stamp-t03-$($c.field)" @{ ($c.field) = $c.value }
        $r = Send-Ticket $body
        $has = $r.Json -and $r.Json.details -and ($r.Json.details.PSObject.Properties.Name -contains $c.field)
        Assert-That 'T03' "tipo incorrecto en '$($c.field)' -> 400 con detalle de ese campo" ($r.Status -eq 400 -and $has) (Detail $r)
    }
    Assert-That 'T03' 'ningun ticket creado por tipos incorrectos' ((Get-TicketCount) -eq $before) ''

    # T03b: regla de negocio que solo conoce Django (asunto demasiado corto): el 400 de Django llega al cliente
    $mark = Get-LastExecutionId
    $r = Send-Ticket (New-Ticket "WF1-$stamp-t03b" @{ subject = 'ab' })
    Assert-That 'T03b' 'un 400 de Django se devuelve al cliente con su detalle' ($r.Status -eq 400 -and $r.Json.code -eq 'validation_error' -and ($r.Json.details.PSObject.Properties.Name -contains 'subject')) (Detail $r)
    $e1 = @(Wait-Executions $mark $WF1 1)
    Assert-That 'T03b' 'se trata como error del cliente: ejecucion en success (no es un fallo del workflow)' ($e1.Count -eq 1 -and $e1[0].status -eq 'success') ($e1 | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- T04 Django responde 500
    $mark = Get-LastExecutionId
    $id04 = "QA-500-$stamp"
    $r = Send-Ticket (New-Ticket $id04)
    Assert-That 'T04' 'HTTP 502 upstream_error (el 500 de Django no se oculta como exito)' ($r.Status -eq 502 -and $r.Json.code -eq 'upstream_error') (Detail $r)
    $e1 = @(Wait-Executions $mark $WF1 1)
    $f = if ($e1.Count -eq 1) { ConvertFrom-HandledFailure $e1[0].error } else { $null }
    Assert-That 'T04' 'la ejecucion de WF1 queda en error: type=http_5xx retryable=yes, y NO lanza WF2' ($e1.Count -eq 1 -and $e1[0].status -eq 'error' -and $e1[0].error -match '^HANDLED_FAILURE type=http_5xx retryable=yes data=' -and (Count-Executions $mark $WF2 2) -eq 0) ($e1 | ConvertTo-Json -Compress)
    Assert-That 'T04' 'el fallo decodificado identifica nodo, ticket y causa' ($f -and $f.node -eq 'Create ticket in Django' -and $f.ticket_external_id -eq $id04 -and $f.detail -eq 'HTTP 500') ($f | ConvertTo-Json -Compress)
    Assert-That 'T04' 'no se crea el ticket' ((Get-TicketCount $id04) -eq 0) ''

    # ---------------------------------------------------------------- T05 API inaccesible
    $mark = Get-LastExecutionId
    $id05 = "WF1-$stamp-t05"
    Invoke-Compose @('stop', 'api')
    try {
        Start-Sleep -Seconds 2
        $r = Send-Ticket (New-Ticket $id05)
        Assert-That 'T05' 'HTTP 503 upstream_unavailable con la API caida' ($r.Status -eq 503 -and $r.Json.code -eq 'upstream_unavailable') (Detail $r)
        $e1 = @(Wait-Executions $mark $WF1 1)
        $f = if ($e1.Count -eq 1) { ConvertFrom-HandledFailure $e1[0].error } else { $null }
        Assert-That 'T05' 'ejecucion en error: type=connection retryable=yes (el mensaje NO fue reescrito por n8n)' ($e1.Count -eq 1 -and $e1[0].status -eq 'error' -and $e1[0].error -match '^HANDLED_FAILURE type=connection retryable=yes data=') ($e1 | ConvertTo-Json -Compress)
        Assert-That 'T05' 'el fallo decodificado identifica nodo y ticket' ($f -and $f.node -eq 'Create ticket in Django' -and $f.ticket_external_id -eq $id05) ($f | ConvertTo-Json -Compress)
        if ($f) { Write-Host ("      detalle real del error de red: " + $f.detail) }
    }
    finally {
        Invoke-Compose @('start', 'api')
        Wait-ServiceHealthy 'api'
    }
    # El ticket NO se creo, pero reenviar es seguro (idempotente) y ahora si se acepta.
    $r = Send-Ticket (New-Ticket $id05)
    Assert-That 'T05' 'tras recuperar la API, reenviar la misma solicitud la acepta (201)' ($r.Status -eq 201) (Detail $r)

    # ---------------------------------------------------------------- T06 timeout (ambiguo)
    $mark = Get-LastExecutionId
    $id06 = "QA-SLOW-$stamp"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Send-Ticket (New-Ticket $id06)
    $sw.Stop()
    $t06 = Get-Date
    Assert-That 'T06' 'HTTP 504 upstream_timeout' ($r.Status -eq 504 -and $r.Json.code -eq 'upstream_timeout') (Detail $r)
    Assert-That 'T06' ('responde a los ~8 s del timeout, no espera los 15 s de Django (tardo {0:N1} s)' -f $sw.Elapsed.TotalSeconds) ($sw.Elapsed.TotalSeconds -ge 7 -and $sw.Elapsed.TotalSeconds -lt 13) ''
    $e1 = @(Wait-Executions $mark $WF1 1)
    $f = if ($e1.Count -eq 1) { ConvertFrom-HandledFailure $e1[0].error } else { $null }
    Assert-That 'T06' 'ejecucion en error: type=timeout retryable=yes' ($e1.Count -eq 1 -and $e1[0].status -eq 'error' -and $e1[0].error -match '^HANDLED_FAILURE type=timeout retryable=yes data=') ($e1 | ConvertTo-Json -Compress)
    if ($f) { Write-Host ("      detalle real del error de timeout: " + $f.detail) }
    Start-Sleep -Seconds 10   # Django termina su espera de 15 s y crea el ticket aunque el cliente se rindio
    Assert-That 'T06' 'timeout AMBIGUO: Django termino y el ticket SI existe aunque se respondio 504' ((Get-TicketCount $id06) -eq 1) ''
    Assert-That 'T06' 'WF2 no se lanzo para ese ticket' ((Count-Executions $mark $WF2 1) -eq 0) ''

    # ---------------------------------------------------------------- T06b recuperacion de un ticket atascado
    if ($SkipSlowRecovery) {
        Write-Host 'OMITIDA T06b (recuperacion de un ticket atascado, -SkipSlowRecovery)'
    }
    else {
        Write-Host '      esperando a que el ticket supere el periodo de gracia de 120 s (hasta ~2 min)...'
        $deadline = (Get-Date).AddSeconds(200)
        do {
            Start-Sleep -Seconds 5
            $age = [double](Invoke-Sql "select extract(epoch from (now() - created_at)) from tickets_ticket where external_id = '$id06'")
        } while ($age -lt 125 -and (Get-Date) -lt $deadline)
        # 1) Un reenvio ANTES de la gracia habria sido un duplicado normal; aqui ya paso. 2) Se reprocesa.
        $mark = Get-LastExecutionId
        $r = Send-Ticket (New-Ticket $id06)
        Assert-That 'T06b' 'reenviar el ticket atascado -> 200 duplicate con reprocessing=true' ($r.Status -eq 200 -and $r.Json.status -eq 'duplicate' -and $r.Json.reprocessing -eq $true) (Detail $r)
        $e2 = @(Wait-Executions $mark $WF2 1)
        Assert-That 'T06b' 'WF2 se lanza para reprocesarlo' ($e2.Count -eq 1 -and $e2[0].status -eq 'success') ($e2 | ConvertTo-Json -Compress)
        Assert-That 'T06b' 'sigue habiendo un unico ticket (sin duplicados)' ((Get-TicketCount $id06) -eq 1) ''
    }

    # ---------------------------------------------------------------- T12 credenciales/token del webhook
    $mark = Get-LastExecutionId; $before = Get-TicketCount
    $r1 = Send-Ticket (New-Ticket "WF1-$stamp-t12a") ''
    $r2 = Send-Ticket (New-Ticket "WF1-$stamp-t12b") 'token-incorrecto'
    $r3 = Send-Ticket (New-Ticket "WF1-$stamp-t12c") $internalToken
    Assert-That 'T12' 'sin token -> 403' ($r1.Status -eq 403) (Detail $r1)
    Assert-That 'T12' 'token incorrecto -> 403' ($r2.Status -eq 403) (Detail $r2)
    Assert-That 'T12' 'el token INTERNO no sirve en el webhook publico -> 403' ($r3.Status -eq 403) (Detail $r3)
    Assert-That 'T12' 'ninguna peticion rechazada crea ejecucion ni ticket' ((Count-Executions $mark $WF1 2) -eq 0 -and (Get-TicketCount) -eq $before) ''
    $j = '{"ticket_id": 1}'
    $i1 = Invoke-Http -Method POST -Url $internal -Body $j
    $i2 = Invoke-Http -Method POST -Url $internal -Headers @{ 'X-Webhook-Token' = $intakeToken } -Body $j
    Assert-That 'T12' 'webhook interno de WF2: sin token -> 403' ($i1.Status -eq 403) (Detail $i1)
    Assert-That 'T12' 'webhook interno de WF2: el token PUBLICO no sirve -> 403' ($i2.Status -eq 403) (Detail $i2)

    # ---------------------------------------------------------------- T14 duplicados
    $mark = Get-LastExecutionId
    $id14 = "WF1-$stamp-t14a"
    $a = Send-Ticket (New-Ticket $id14)
    $b = Send-Ticket (New-Ticket $id14)
    Assert-That 'T14' 'primer envio 201; segundo envio 200 duplicate sin reprocesar' ($a.Status -eq 201 -and $b.Status -eq 200 -and $b.Json.status -eq 'duplicate' -and $b.Json.reprocessing -eq $false -and $a.Json.ticket_id -eq $b.Json.ticket_id) ((Detail $a) + ' | ' + (Detail $b))
    Assert-That 'T14' 'WF2 se lanza UNA sola vez y hay un unico ticket' ((Count-Executions $mark $WF2 4) -eq 1 -and (Get-TicketCount $id14) -eq 1) ''
    $mails14 = @(Wait-Mail $id14 1 30); Start-Sleep -Seconds 6
    Assert-That 'T14' 'prueba definitiva: UN solo correo en Mailpit (ni siquiera con el reenvio duplicado)' ((@(Get-MailFor $id14)).Count -eq 1) "correos=$((@(Get-MailFor $id14)).Count)"

    # T14b: 5 peticiones simultaneas con el mismo external_id
    $mark = Get-LastExecutionId
    $id14b = "WF1-$stamp-t14b"
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $payload = (New-Ticket $id14b) | ConvertTo-Json -Compress
    $tasks = 1..5 | ForEach-Object {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $webhook)
        $req.Headers.Add('X-Webhook-Token', $intakeToken)
        $req.Content = New-Object System.Net.Http.StringContent($payload, [System.Text.Encoding]::UTF8, 'application/json')
        $client.SendAsync($req)
    }
    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks))
    $codes = @($tasks | ForEach-Object { [int]$_.Result.StatusCode } | Sort-Object)
    $client.Dispose()
    Assert-That 'T14b' ("5 peticiones simultaneas -> exactamente un 201 y cuatro 200 (obtenido: {0})" -f ($codes -join ',')) (($codes -join ',') -eq '200,200,200,200,201') ''
    Assert-That 'T14b' 'un unico ticket y WF2 lanzado una sola vez' ((Get-TicketCount $id14b) -eq 1 -and (Count-Executions $mark $WF2 5) -eq 1) ''
    $null = Wait-Mail $id14b 1 30; Start-Sleep -Seconds 6
    Assert-That 'T14b' 'prueba definitiva: 5 peticiones simultaneas -> UN solo correo en Mailpit' ((@(Get-MailFor $id14b)).Count -eq 1) "correos=$((@(Get-MailFor $id14b)).Count)"

    # ---------------------------------------------------------------- T18 entradas anomalas
    # (a) Rechazos del BORDE de n8n: ocurren antes de ejecutar el workflow, asi que no crean ejecucion ni ticket.
    $mark = Get-LastExecutionId; $before = Get-TicketCount
    $r = Send-Ticket '{esto no es json'
    Assert-That 'T18' 'JSON malformado -> 422 de n8n, sin filtrar trazas internas' ($r.Status -eq 422 -and $r.Json.message -eq 'Failed to parse request body' -and $r.Raw -notmatch 'at .*\.js|node_modules|/usr/local') (Detail $r)
    $huge = '{"external_id":"WF1-big","message":"' + ('A' * 1600000) + '"}'
    $r = Send-Ticket $huge
    # Limitacion conocida de n8n: el limite (N8N_PAYLOAD_SIZE_MAX=1 MiB) SI se aplica, pero responde un 500 generico en vez de 413.
    Assert-That 'T18' 'cuerpo de ~1,5 MiB (limite 1 MiB) -> rechazado (n8n responde 500 generico), sin trazas' ($r.Status -ge 400 -and $r.Raw -notmatch 'PayloadTooLarge|node_modules|at .*\.js') (Detail $r)
    Write-Host ("      respuesta real al cuerpo gigante: HTTP {0}" -f $r.Status)
    Assert-That 'T18' 'los rechazos del borde no crean ejecuciones ni tickets' ((Count-Executions $mark $WF1 2) -eq 0 -and (Get-TicketCount) -eq $before) ''

    # (b) Entradas que SI ejecutan el workflow y se resuelven con un 400 controlado.
    $r = Invoke-Http -Method POST -Url $webhook -Headers @{ 'X-Webhook-Token' = $intakeToken } -Body 'texto plano' -ContentType 'text/plain'
    Assert-That 'T18' 'Content-Type text/plain -> 400 controlado' ($r.Status -eq 400) (Detail $r)
    $r = Send-Ticket (New-Ticket "WF1-$stamp-t18big" @{ message = ('x' * 5001) })
    Assert-That 'T18' 'mensaje de 5001 caracteres -> 400 (regla de Django) con detalle en message' ($r.Status -eq 400 -and ($r.Json.details.PSObject.Properties.Name -contains 'message')) (Detail $r)
    $r = Invoke-Http -Method GET -Url $webhook -Headers @{ 'X-Webhook-Token' = $intakeToken }
    Assert-That 'T18' 'GET sobre el webhook (solo acepta POST) -> 404' ($r.Status -eq 404) (Detail $r)
    $r = Send-Ticket '[]'
    Assert-That 'T18' 'cuerpo JSON que es un array -> 400 non_field_errors' ($r.Status -eq 400 -and ($r.Json.details.PSObject.Properties.Name -contains 'non_field_errors')) (Detail $r)
}
catch {
    Write-Host "ERROR inesperado en las pruebas: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    # Deja el entorno como estaba: la API nunca debe quedar parada.
    if ((Get-ServiceHealth 'api') -ne 'healthy') { Invoke-Compose @('start', 'api') }
    exit 2
}

$failed = Write-Summary
exit ([int]($failed -gt 0))
