<#
.SYNOPSIS
    T12: credenciales INCORRECTAS de n8n hacia Django (la API key de la credencial "Django API Key" es erronea).

.DESCRIPTION
    Sustituye temporalmente esa credencial en n8n por una con una clave invalida (por CLI, con la misma id) y comprueba:
      - WF1: el cliente recibe 502 upstream_rejected (problema de CONFIGURACION: no se culpa al cliente ni se reintenta),
             la ejecucion queda en error http_4xx / retryable=no y WF3 intenta registrarlo (Django rechaza al propio WF3
             con la misma clave, asi que llega la ALERTA por correo: el fallo no se pierde);
      - WF2: reprocesar un ticket falla en la etapa Get ticket con http_4xx / no reintentable.
    Despues RESTAURA la credencial correcta ejecutando import-n8n.ps1 y comprueba que todo vuelve a funcionar.
    El archivo temporal con la clave erronea (que no es un secreto real) se borra siempre.

.EXAMPLE
    .\tests\integration\credentials-wrong.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib.ps1"

$stamp = Get-Date -Format 'HHmmss'
$WF1 = 'wfTicketIntake01'
$WF2 = 'wfAiTriageNotify'
$WF3 = 'wfErrorMonitor03'
$genDir  = Join-Path $script:Root 'n8n\credentials\generated'
$wrongFile = Join-Path $genDir 'wrong-django.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Restore-Credentials {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'scripts\import-n8n.ps1') 2>&1 |
        Select-String -Pattern 'Importacion|rror|Las versiones' | ForEach-Object { Write-Host ('      ' + $_.Line) }
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo restaurar la credencial con import-n8n.ps1' }
}

Write-Host "== T12 - credenciales incorrectas de n8n hacia Django ($stamp)"
foreach ($s in 'api', 'n8n', 'postgres', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
Wait-WorkflowsReady
Clear-Mailpit

# Un ticket YA notificado para reprocesarlo despues (se crea antes de romper la credencial)
$ok = Send-Ticket (New-Ticket "CRED-$stamp-base" @{ message = 'No puedo pagar mi factura, me sale un error al pagar.' })
$baseTicket = [int]$ok.Json.ticket_id
$null = Wait-Ticket -TicketId $baseTicket -TimeoutSec 40 -Predicate { param($x) $x.status -eq 'notified' }

try {
    New-Item -ItemType Directory -Force -Path $genDir | Out-Null
    $wrong = '[{"id":"credDjangoApiKey1","name":"Django API Key","type":"httpHeaderAuth","data":{"name":"X-API-Key","value":"wrong-key-used-only-for-this-test"}}]'
    [System.IO.File]::WriteAllText($wrongFile, $wrong, $utf8NoBom)
    Invoke-Compose @('exec', '-T', 'n8n', 'n8n', 'import:credentials', '--input=/import/credentials/generated/wrong-django.json')
    Start-Sleep -Seconds 3

    # ---------------------------------------------------------------- WF1 con la credencial incorrecta
    $mark = Get-LastExecutionId
    $c = Send-Ticket (New-Ticket "CRED-$stamp-wf1")
    $w1 = @(Wait-Executions $mark $WF1 1)
    $f = if ($w1.Count -ge 1) { ConvertFrom-HandledFailure $w1[0].error } else { $null }
    Assert-That 'T12d' 'WF1: Django rechaza la clave -> el cliente recibe 502 upstream_rejected (config, no culpa del cliente)' ($c.Status -eq 502 -and $c.Json.code -eq 'upstream_rejected') (Detail $c)
    Assert-That 'T12d' 'la ejecucion queda en error http_4xx, NO reintentable, en la etapa Create ticket' ($w1.Count -eq 1 -and $w1[0].status -eq 'error' -and $f -and $f.node -eq 'Create ticket in Django' -and $f.type -eq 'http_4xx' -and $f.retryable -eq 'no' -and $f.detail -eq 'HTTP 401') ($w1 | ConvertTo-Json -Compress)
    Assert-That 'T12d' 'no se crea ningun ticket con una credencial incorrecta' ((Get-TicketCount "CRED-$stamp-wf1") -eq 0) ''

    # WF3 usa la MISMA credencial: tampoco puede registrar -> alerta por correo (no se pierde en silencio)
    $alerts = @()
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) { $alerts = @(Get-AlertMails); if ($alerts.Count -ge 1) { break }; Start-Sleep -Seconds 3 }
    Assert-That 'T12d' 'WF3 no puede registrar (Django le rechaza la misma clave): llega una ALERTA por correo' ($alerts.Count -ge 1) "alertas=$($alerts.Count)"
    if ($alerts.Count -ge 1) {
        $a = Get-MailDetail $alerts[0].ID
        Assert-That 'T12d' 'la alerta identifica workflow, etapa y tipo, y NO contiene la clave erronea' ($a.Text -match 'Stage:      Create ticket in Django' -and $a.Text -match 'Type:       http_4xx' -and $a.Text -match 'Do NOT just retry' -and $a.Text -notmatch 'wrong-key') $a.Text
    }
    $null = Wait-Executions $mark $WF3 1 60

    # ---------------------------------------------------------------- WF2 con la credencial incorrecta
    $mark = Get-LastExecutionId
    $null = Send-Reprocess $baseTicket
    $w2 = @(Wait-Executions $mark $WF2 1 40)
    $f2 = if ($w2.Count -ge 1) { ConvertFrom-HandledFailure $w2[0].error } else { $null }
    Assert-That 'T12d' 'WF2: reprocesar con la clave incorrecta falla en Get ticket: http_4xx, no reintentable, con el ticket' ($w2.Count -eq 1 -and $w2[0].status -eq 'error' -and $f2 -and $f2.node -eq 'Get ticket' -and $f2.type -eq 'http_4xx' -and $f2.retryable -eq 'no' -and $f2.ticket_id -eq $baseTicket) ($w2 | ConvertTo-Json -Compress)
    $null = Wait-Executions $mark $WF3 1 60
}
finally {
    if (Test-Path -LiteralPath $wrongFile) { [System.IO.File]::Delete($wrongFile) }
    Write-Host '== Restaurando la credencial correcta (import-n8n.ps1)'
    Restore-Credentials
}

# ---------------------------------------------------------------- tras restaurar todo vuelve a funcionar
Wait-WorkflowsReady
Clear-Mailpit
$ok2 = Send-Ticket (New-Ticket "CRED-$stamp-after")
$t = Wait-Ticket -TicketId ([int]$ok2.Json.ticket_id) -TimeoutSec 40 -Predicate { param($x) $x.status -eq 'notified' }
Assert-That 'T12d' 'tras restaurar la credencial, el flujo completo vuelve a funcionar (201, ticket notificado, 1 correo)' ($ok2.Status -eq 201 -and $t.status -eq 'notified' -and (@(Wait-Mail "CRED-$stamp-after" 1)).Count -eq 1) (Detail $ok2)
Assert-That 'T12d' 'no queda ningun archivo temporal con claves en credentials/generated' (-not (Test-Path -LiteralPath $wrongFile)) ''

$failed = Write-Summary
exit ([int]($failed -gt 0))
