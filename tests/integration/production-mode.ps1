<#
.SYNOPSIS
    Modo "produccion": con QA_TOOLS_ENABLED=false las herramientas de QA NO existen.

.DESCRIPTION
    Recrea SOLO el contenedor de la API con QA_TOOLS_ENABLED=false (la variable de la sesion tiene prioridad sobre .env),
    comprueba que el LLM simulado no existe, que los prefijos QA-500-/QA-SLOW- ya no se interpretan y que los tests de
    Django siguen pasando, y SIEMPRE restaura el modo desarrollo al terminar (bloque finally).
    No toca los datos ni los otros servicios. Crea 2 tickets de prueba directamente en la API.

.EXAMPLE
    .\tests\integration\production-mode.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib.ps1"

$stamp = Get-Date -Format 'HHmmss'
function Get-ApiQaFlag { return ((& docker compose exec -T api printenv QA_TOOLS_ENABLED) -join '').Trim() }
function Test-LlmMockStatus {
    return (Invoke-Http -Method POST -Url "http://127.0.0.1:$(Get-Port 'API_HOST_PORT' 8000)/qa/llm/v1/chat/completions" -Body '{}').Status
}

Write-Host "== Modo produccion (QA_TOOLS_ENABLED=false) ($stamp)"
foreach ($s in 'api', 'n8n', 'postgres', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
$devFlag = Get-ApiQaFlag
$devLlmStatus = Test-LlmMockStatus
Assert-That 'PROD' 'punto de partida: modo desarrollo (QA activo) y el LLM simulado existe (no responde 404)' ($devFlag -eq 'true' -and $devLlmStatus -ne 404) "flag=$devFlag llm=$devLlmStatus"

try {
    $env:QA_TOOLS_ENABLED = 'false'
    Invoke-Compose @('up', '-d', '--no-deps', '--wait', 'api')
    Assert-That 'PROD' 'la API se recrea con QA_TOOLS_ENABLED=false' ((Get-ApiQaFlag) -eq 'false') (Get-ApiQaFlag)
    Assert-That 'PROD' 'el LLM simulado NO existe: 404' ((Test-LlmMockStatus) -eq 404) ''

    $r500 = Invoke-Django POST '/api/tickets/' (New-Ticket "QA-500-prod-$stamp")
    Assert-That 'PROD' 'el prefijo QA-500- ya no inyecta un 500: el ticket se crea normalmente (201)' ($r500.Status -eq 201) (Detail $r500)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rSlow = Invoke-Django POST '/api/tickets/' (New-Ticket "QA-SLOW-prod-$stamp")
    $sw.Stop()
    Assert-That 'PROD' 'el prefijo QA-SLOW- ya no ralentiza: 201 en menos de 5 s' ($rSlow.Status -eq 201 -and $sw.Elapsed.TotalSeconds -lt 5) ("{0} en {1:N1} s" -f $rSlow.Status, $sw.Elapsed.TotalSeconds)

    $logs = (& docker compose logs api --no-color 2>&1 | Out-String)
    Assert-That 'PROD' 'el log de arranque no declara la inyeccion de fallos activa' (-not $logs.Contains('inyeccion de fallos ACTIVA')) ''

    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $tests = (& docker compose exec -T api python manage.py test --noinput 2>&1 | Out-String); $testsExit = $LASTEXITCODE } finally { $ErrorActionPreference = $previous }
    $ran = if ($tests -match 'Ran (\d+) tests') { [int]$Matches[1] } else { 0 }
    $tail = (($tests -split "`n" | Select-Object -Last 6) -join ' ')
    Assert-That 'PROD' "los tests de Django pasan tambien en modo produccion ($ran tests)" ($testsExit -eq 0 -and $ran -ge 80) $tail
}
finally {
    Remove-Item Env:\QA_TOOLS_ENABLED -ErrorAction SilentlyContinue
    Invoke-Compose @('up', '-d', '--no-deps', '--wait', 'api')
}

Assert-That 'PROD' 'restaurado: modo desarrollo otra vez (QA activo y LLM simulado presente)' ((Get-ApiQaFlag) -eq 'true' -and (Test-LlmMockStatus) -ne 404) "flag=$(Get-ApiQaFlag)"
$e2e = Send-Ticket (New-Ticket "PROD-RESTORE-$stamp" @{ message = 'No puedo pagar mi factura, me sale un error al pagar.' })
$t = $null
if ($e2e.Status -eq 201) { $t = Wait-Ticket -TicketId ([int]$e2e.Json.ticket_id) -TimeoutSec 60 -Predicate { param($x) $x.status -eq 'notified' } }
Assert-That 'PROD' 'tras restaurar, el flujo completo vuelve a funcionar (201 y ticket notificado)' ($e2e.Status -eq 201 -and $null -ne $t) (Detail $e2e)

$failed = Write-Summary
exit ([int]($failed -gt 0))
