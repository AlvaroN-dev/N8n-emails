<#
.SYNOPSIS
    T15 y T16: reinicio de contenedores y persistencia tras `docker compose down` (SIN -v).

.DESCRIPTION
    Compara un INVENTARIO del estado antes y despues:
      - tickets y eventos de error en PostgreSQL,
      - workflows publicados, credenciales (id/nombre/tipo; nunca su contenido) y usuario owner en n8n.
    T15: `docker compose restart` (todos los servicios) -> mismo estado, workflows realmente en marcha y flujo completo OK.
    T16: `docker compose down` + `up --wait` (volumenes conservados) -> mismo estado y el flujo completo OK, lo que
         ademas demuestra que las credenciales siguen descifrandose (N8N_ENCRYPTION_KEY y volumen persistentes).
    El buzon de Mailpit es EFIMERO por diseno (sin volumen): se verifica que no sobrevive a `down`.
    NO usa `-v`: no se borra ningun volumen.

.EXAMPLE
    .\tests\integration\restart-persistence.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib.ps1"

$stamp = Get-Date -Format 'HHmmss'

function Get-Inventory {
    $text = (& docker compose exec -T n8n node --no-warnings /import/src/tools/inventory.js | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo leer el inventario de n8n' }
    $inv = $text | ConvertFrom-Json
    $wf = @($inv.workflows | ForEach-Object { '{0}|{1}|{2}' -f $_.id, $_.name, $_.published }) -join ';'
    $cr = @($inv.credentials | ForEach-Object { '{0}|{1}|{2}' -f $_.id, $_.name, $_.type }) -join ';'
    return [pscustomobject]@{
        Tickets = [int](Invoke-Sql 'select count(*) from tickets_ticket')
        Events  = [int](Invoke-Sql 'select count(*) from tickets_errorevent')
        Workflows = $wf
        WorkflowCount = @($inv.workflows).Count
        PublishedCount = @($inv.workflows | Where-Object { $_.published }).Count
        Credentials = $cr
        CredentialCount = @($inv.credentials).Count
        Users = [int]$inv.users
    }
}
function Test-FullFlow([string]$Label) {
    $id = "PERSIST-$stamp-$Label"
    $r = Send-Ticket (New-Ticket $id @{ message = 'No puedo pagar mi factura, me sale un error al pagar.' })
    $t = $null
    if ($r.Status -eq 201) { $t = Wait-Ticket -TicketId ([int]$r.Json.ticket_id) -TimeoutSec 60 -Predicate { param($x) $x.status -eq 'notified' } }
    $mails = @(Wait-Mail $id 1 30)
    return [pscustomobject]@{ Http = $r.Status; Status = $(if ($t) { $t.status } else { '' }); Source = $(if ($t) { $t.triage_source } else { '' }); Mails = $mails.Count }
}
function Wait-AllHealthy {
    foreach ($s in 'postgres', 'api', 'n8n', 'mailpit') { Wait-ServiceHealthy $s 180 }
}

Write-Host "== T15/T16 - reinicio y persistencia ($stamp)"
foreach ($s in 'api', 'n8n', 'postgres', 'mailpit') { if ((Get-ServiceHealth $s) -ne 'healthy') { throw "El servicio $s no esta healthy" } }
Wait-WorkflowsReady

$before = Get-Inventory
Write-Host ("      estado inicial: tickets={0} eventos={1} workflows={2} (publicados {3}) credenciales={4} owners={5}" -f $before.Tickets, $before.Events, $before.WorkflowCount, $before.PublishedCount, $before.CredentialCount, $before.Users)
Assert-That 'T15' 'punto de partida valido: 3 workflows publicados, >=5 credenciales y un owner' ($before.PublishedCount -eq 3 -and $before.CredentialCount -ge 5 -and $before.Users -ge 1) ''

# ============================================================== T15 reinicio de TODOS los contenedores
Invoke-Compose @('restart')
Wait-AllHealthy
Wait-WorkflowsReady
$after = Get-Inventory
Assert-That 'T15' 'tras `docker compose restart` los 4 servicios vuelven healthy' ($true) ''
Assert-That 'T15' 'PostgreSQL conserva todos los datos (tickets y eventos)' ($after.Tickets -eq $before.Tickets -and $after.Events -eq $before.Events) "tickets $($before.Tickets)->$($after.Tickets) eventos $($before.Events)->$($after.Events)"
Assert-That 'T15' 'n8n conserva los mismos workflows (todos publicados), credenciales y owner' ($after.Workflows -eq $before.Workflows -and $after.Credentials -eq $before.Credentials -and $after.Users -eq $before.Users) ''
$flow = Test-FullFlow 'restart'
Assert-That 'T15' 'el flujo completo funciona tras el reinicio: 201, ticket notificado con IA y UN correo' ($flow.Http -eq 201 -and $flow.Status -eq 'notified' -and $flow.Source -eq 'ai' -and $flow.Mails -eq 1) ($flow | ConvertTo-Json -Compress)

# ============================================================== T16 down + up SIN -v
$ticketsPre = [int](Invoke-Sql 'select count(*) from tickets_ticket')
$eventsPre = [int](Invoke-Sql 'select count(*) from tickets_errorevent')
$mailsPre = @((Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/messages?limit=1").messages).Count
Invoke-Compose @('down')
$running = @(& docker compose ps -q 2>$null).Count
$vols = @(& docker volume ls --filter 'label=com.docker.compose.project=ticket-triage-n8n' --format '{{.Name}}')
Assert-That 'T16' 'tras `down` no queda ningun contenedor, pero SI los 2 volumenes (n8n_data y postgres_data)' ($running -eq 0 -and ($vols -contains 'ticket-triage-n8n_n8n_data') -and ($vols -contains 'ticket-triage-n8n_postgres_data')) "contenedores=$running volumenes=$($vols -join ',')"
Invoke-Compose @('up', '-d', '--wait')
Wait-AllHealthy
Wait-WorkflowsReady
$after2 = Get-Inventory
$setup = (Invoke-RestMethod "http://127.0.0.1:$($script:N8nPort)/rest/settings").data.userManagement.showSetupOnFirstLoad
Assert-That 'T16' 'tras `down`+`up` PostgreSQL conserva todos los datos' ($after2.Tickets -ge $ticketsPre -and $after2.Events -ge $eventsPre) "tickets $ticketsPre->$($after2.Tickets) eventos $eventsPre->$($after2.Events)"
Assert-That 'T16' 'n8n conserva workflows publicados y credenciales, y el owner sigue creado (no pide registro)' ($after2.PublishedCount -eq 3 -and $after2.Workflows -eq $before.Workflows -and $after2.Credentials -eq $before.Credentials -and $after2.Users -eq $before.Users -and $setup -eq $false) "setup=$setup"
Assert-That 'T16' 'el buzon de Mailpit es EFIMERO por diseno: no sobrevive a `down` (sin volumen)' ($mailsPre -ge 1 -and (@((Invoke-RestMethod -Uri "$($script:MailpitUrl)/api/v1/messages?limit=1").messages)).Count -eq 0) "antes=$mailsPre"
$flow2 = Test-FullFlow 'downup'
Assert-That 'T16' 'el flujo completo funciona tras down/up: las credenciales siguen descifrandose (clave y volumen persistentes)' ($flow2.Http -eq 201 -and $flow2.Status -eq 'notified' -and $flow2.Source -eq 'ai' -and $flow2.Mails -eq 1) ($flow2 | ConvertTo-Json -Compress)

$failed = Write-Summary
exit ([int]($failed -gt 0))
