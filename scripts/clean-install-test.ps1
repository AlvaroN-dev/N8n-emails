<#
.SYNOPSIS
    Prueba de INSTALACION LIMPIA en un proyecto Docker Compose AISLADO y desechable. No toca tu instalacion real.

.DESCRIPTION
    Levanta una copia completa (PostgreSQL, API, n8n, Mailpit) con otro nombre de proyecto (tt-clean), otros puertos,
    otros volumenes y otros secretos generados al vuelo, y comprueba desde cero que:
      1. el entorno arranca sano y VACIO (0 tickets, n8n sin owner);
      2. import-n8n.ps1 importa y publica los 3 workflows (y crea las credenciales) en una instalacion nueva;
      3. el smoke test y las suites de integracion pasan contra esa instalacion;
      4. la proteccion SSRF de n8n bloquea destinos internos no permitidos (y la sonda de control, sin proteccion, conecta).
    Al terminar elimina el proyecto desechable (down -v) y demuestra que tus volumenes y tus datos siguen intactos.

    Salvaguardas: se verifica que el proyecto activo es tt-clean ANTES de cualquier `down -v`, y que cada volumen a
    borrar pertenece a ese proyecto. Las variables COMPOSE_PROJECT_NAME / COMPOSE_ENV_FILES / TT_ENV_FILE solo existen
    en este proceso y sus hijos.

.PARAMETER SkipSuites
    Omite las suites de integracion (~12 min); solo comprueba arranque, importacion, smoke y SSRF.

.PARAMETER KeepRunning
    No elimina el proyecto desechable al terminar (para inspeccionarlo; elimínalo despues con -Teardown).

.PARAMETER Teardown
    Solo elimina un proyecto desechable que se hubiera quedado (con las mismas salvaguardas).

.EXAMPLE
    .\scripts\clean-install-test.ps1
#>
[CmdletBinding()]
param([switch]$SkipSuites, [switch]$KeepRunning, [switch]$Teardown)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$Project   = 'tt-clean'
$RealName  = 'ticket-triage-n8n'
$EnvName   = '.env.clean'
$EnvPath   = Join-Path $root $EnvName
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok })
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name) } else { Write-Host ("FAIL  {0}  [{1}]" -f $Name, $Detail) -ForegroundColor Red }
}
function Get-Short([string]$Text, [int]$Max = 200) {
    $flat = ($Text.Trim() -replace '\s+', ' ')
    if ($flat.Length -gt $Max) { return $flat.Substring(0, $Max) }
    return $flat
}
function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" }

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose @ComposeArgs 2>&1 | ForEach-Object { "$_" } | Out-Host }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') termino con codigo $LASTEXITCODE" }
}
# Salida de un comando docker SIN pasar por el pipeline de errores de PowerShell 5.1.
function Get-Docker([string[]]$DockerArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& docker @DockerArgs 2>$null) }
    finally { $ErrorActionPreference = $previous }
}

# ---- Aislamiento: SOLO en este proceso y sus hijos ------------------------------------------------------------------
$env:COMPOSE_PROJECT_NAME = $Project
$env:COMPOSE_ENV_FILES    = $EnvName
$env:TT_ENV_FILE          = $EnvName

# Salvaguarda: antes de cualquier operacion destructiva, el proyecto activo DEBE ser el desechable.
function Assert-Isolated {
    $active = (Get-Docker @('compose', 'config', '--format', 'json') | Out-String | ConvertFrom-Json).name
    if ($active -ne $Project -or $active -eq $RealName) {
        throw "ABORTADO: el proyecto Compose activo es '$active', no '$Project'. No se ejecuta nada destructivo."
    }
}
function Remove-Disposable([switch]$KeepEnvFile) {
    Assert-Isolated
    $vols = @(Get-Docker @('volume', 'ls', '--filter', "label=com.docker.compose.project=$Project", '--format', '{{.Name}}'))
    foreach ($v in $vols) {
        if (-not $v.StartsWith("${Project}_")) { throw "ABORTADO: el volumen '$v' no pertenece al proyecto $Project." }
    }
    Invoke-Compose @('down', '-v', '--remove-orphans')
    if (-not $KeepEnvFile -and (Test-Path -LiteralPath $EnvPath)) { [System.IO.File]::Delete($EnvPath) }
    $left = @(Get-Docker @('volume', 'ls', '--filter', "label=com.docker.compose.project=$Project", '--format', '{{.Name}}'))
    return $left.Count
}

# Estado de la instalacion REAL antes de empezar (para demostrar al final que no se toco).
$realVolumesBefore = @(Get-Docker @('volume', 'ls', '--filter', "label=com.docker.compose.project=$RealName", '--format', '{{.Name}}') | Sort-Object)
$realTicketsBefore = $null
try {
    $realTicketsBefore = [int]((& docker exec "$RealName-postgres-1" psql -U tickets -d tickets -tAc 'select count(*) from tickets_ticket' 2>$null) -join '').Trim()
} catch { }

# En modo -Teardown el .env.clean puede no existir: se crea uno minimo para que Compose pueda resolver el proyecto.
if ($Teardown) {
    if (-not (Test-Path -LiteralPath $EnvPath)) {
        [System.IO.File]::WriteAllText($EnvPath, "POSTGRES_PASSWORD=x`nN8N_ENCRYPTION_KEY=x`nDJANGO_SECRET_KEY=x`nDJANGO_API_KEY=x`n", $utf8NoBom)
    }
    $n = Remove-Disposable
    Write-Host "Proyecto desechable eliminado. Volumenes restantes del proyecto $Project : $n"
    exit 0
}

Write-Host "== PRUEBA DE INSTALACION LIMPIA (proyecto aislado '$Project'; tu instalacion '$RealName' NO se toca)"
$started = Get-Date

try {
    # ---------------------------------------------------------------- 0. entorno nuevo con secretos nuevos y otros puertos
    Write-Step '0/6 Entorno nuevo: secretos aleatorios propios y puertos distintos'
    if (Test-Path -LiteralPath $EnvPath) { [System.IO.File]::Delete($EnvPath) }
    & (Join-Path $PSScriptRoot 'setup.ps1') -EnvFile $EnvName | Out-Host
    $envText = [System.IO.File]::ReadAllText($EnvPath, $utf8NoBom)
    foreach ($kv in @{ N8N_HOST_PORT = '15678'; MAILPIT_HOST_PORT = '18025'; API_HOST_PORT = '18000'; LLM_PROVIDER = 'mock' }.GetEnumerator()) {
        $envText = [regex]::Replace($envText, "(?m)^$($kv.Key)=.*$", "$($kv.Key)=$($kv.Value)")
    }
    [System.IO.File]::WriteAllText($EnvPath, $envText, $utf8NoBom)
    Assert-Isolated
    $realKey = ([System.IO.File]::ReadAllLines((Join-Path $root '.env')) | Where-Object { $_ -like 'N8N_ENCRYPTION_KEY=*' }) -replace '^N8N_ENCRYPTION_KEY=', ''
    $cleanKey = ([System.IO.File]::ReadAllLines($EnvPath) | Where-Object { $_ -like 'N8N_ENCRYPTION_KEY=*' }) -replace '^N8N_ENCRYPTION_KEY=', ''
    Add-Result 'el entorno limpio usa secretos DISTINTOS a los de tu instalacion real' ($realKey -ne $cleanKey -and $cleanKey.Length -eq 64) ''
    # Por si quedo algo de una ejecucion anterior abortada (se conserva el .env.clean recien generado)
    $null = Remove-Disposable -KeepEnvFile

    # ---------------------------------------------------------------- 1. arranque desde cero
    Write-Step '1/6 docker compose up --build --wait (desde cero)'
    Assert-Isolated
    Invoke-Compose @('up', '-d', '--build', '--wait')
    $health = @(foreach ($s in 'postgres', 'api', 'n8n', 'mailpit') { ((& docker compose ps $s --format '{{.Health}}') -join '').Trim() })
    Add-Result 'los 4 servicios arrancan healthy en una instalacion nueva' (@($health | Where-Object { $_ -eq 'healthy' }).Count -eq 4) ($health -join ',')
    $tickets0 = [int]((& docker compose exec -T postgres psql -U tickets -d tickets -tAc 'select count(*) from tickets_ticket') -join '').Trim()
    $setup = (Invoke-RestMethod 'http://127.0.0.1:15678/rest/settings').data.userManagement.showSetupOnFirstLoad
    Add-Result 'la instalacion esta VACIA: 0 tickets y n8n sin owner (showSetupOnFirstLoad=true)' ($tickets0 -eq 0 -and $setup -eq $true) "tickets=$tickets0 setup=$setup"

    # ---------------------------------------------------------------- 2. importacion en la instalacion nueva
    Write-Step '2/6 import-n8n.ps1 en la instalacion nueva (sin crear antes el owner)'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'import-n8n.ps1') 2>&1 | ForEach-Object { "$_" } | Out-Host
    $importOk = ($LASTEXITCODE -eq 0)
    Add-Result 'import-n8n.ps1 termina con exito (credenciales + 3 workflows importados y publicados)' $importOk "codigo=$LASTEXITCODE"
    $pub = (& docker compose exec -T n8n node --no-warnings /import/src/tools/published.js wfTicketIntake01 wfAiTriageNotify wfErrorMonitor03 2>&1 | Out-String).Trim()
    Add-Result 'los 3 workflows estan realmente en marcha (reconciliados por n8n)' ($LASTEXITCODE -eq 0) $pub

    # ---------------------------------------------------------------- 3. smoke de la API
    Write-Step '3/6 smoke test de la API contra la instalacion nueva'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'smoke-api.ps1') -BaseUrl 'http://127.0.0.1:18000' 2>&1 | ForEach-Object { "$_" } | Out-Host
    Add-Result 'smoke-api.ps1: 14/14 contra la instalacion nueva' ($LASTEXITCODE -eq 0) "codigo=$LASTEXITCODE"

    # ---------------------------------------------------------------- 4. suites de integracion
    if ($SkipSuites) { Write-Host '(suites de integracion omitidas: -SkipSuites)' }
    else {
        Write-Step '4/6 suites de integracion contra la instalacion nueva (WF1, WF2, WF3)'
        $suites = @(
            @{ Name = 'WF1 intake (sin T06b)';          File = 'tests\integration\wf01-intake.ps1';  Args = @('-SkipSlowRecovery') },
            @{ Name = 'WF2 IA simulada + correo (sin SLOW)'; File = 'tests\integration\wf02-triage.ps1'; Args = @('-SkipSlow') },
            @{ Name = 'WF3 errores (sin doble fallo)';  File = 'tests\integration\wf03-errors.ps1';  Args = @('-SkipDoubleFailure') }
        )
        foreach ($s in $suites) {
            Write-Host "-- $($s.Name)"
            $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $s.File) @($s.Args) 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            $lines | Where-Object { $_ -match '^FAIL|== Resultado|ERROR inesperado' } | Out-Host
            Add-Result "suite $($s.Name)" ($code -eq 0) "codigo=$code"
        }
    }

    # ---------------------------------------------------------------- 5. SSRF
    Write-Step '5/6 Proteccion SSRF: sondas dentro del proyecto desechable'
    $fixtures = @(
        @{ Id = 'ssrfProbeAllow01'; File = 'ssrf-probe-allow.json';           Expect = 'allow' },
        @{ Id = 'ssrfProbeBlock01'; File = 'ssrf-probe-block-mailpit.json';   Expect = 'block' },
        @{ Id = 'ssrfProbeBlock02'; File = 'ssrf-probe-block-postgres.json';  Expect = 'block' },
        @{ Id = 'ssrfProbeBlock03'; File = 'ssrf-probe-block-metadata.json';  Expect = 'block' }
    )
    foreach ($f in $fixtures) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & docker compose exec -T n8n n8n import:workflow "--input=/import/tests/fixtures/$($f.File)" 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    }
    function Invoke-Probe([string]$Id, [string]$ExtraEnv = '') {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            # `n8n execute` arranca una SEGUNDA instancia de n8n dentro del contenedor: necesita otro puerto para el
            # task broker (5679 lo ocupa el servidor) o falla con "port 5679 is already in use".
            $dargs = @('exec', '-T', '-e', 'N8N_RUNNERS_BROKER_PORT=5680')
            if ($ExtraEnv) { $dargs += @('-e', $ExtraEnv) }
            $dargs += @('n8n', 'n8n', 'execute', "--id=$Id")
            $out = (& docker compose @dargs 2>&1 | ForEach-Object { "$_" } | Out-String)
            return [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
        }
        finally { $ErrorActionPreference = $prev }
    }
    foreach ($f in $fixtures) {
        $r = Invoke-Probe $f.Id
        # Criterios EXACTOS (mensajes observados en n8n 2.42.6), no palabras sueltas: "ok" casaria con "Broker".
        $relevant = @($r.Output -split "`r?`n" | Where-Object { $_ -match 'blocked because|Execution was' } | Select-Object -First 1)
        $shown = if ($relevant.Count -ge 1) { $relevant[0].Trim() } else { Get-Short $r.Output 200 }
        if ($f.Expect -eq 'allow') {
            Add-Result "SSRF: el host permitido (api) SI conecta ($($f.Id))" ($r.Code -eq 0 -and $r.Output -match 'Execution was successful') $shown
        }
        else {
            Add-Result "SSRF: el destino interno NO permitido se BLOQUEA ($($f.Id))" ($r.Code -ne 0 -and $r.Output -match 'blocked because it resolves to a restricted IP address') $shown
            Write-Host ("      respuesta real de n8n: " + $shown)
        }
    }
    # Control positivo: SIN proteccion, la misma sonda conecta -> el bloqueo lo causa la proteccion SSRF
    $c = Invoke-Probe 'ssrfProbeBlock01' 'N8N_SSRF_PROTECTION_ENABLED=false'
    Add-Result 'SSRF (control): con la proteccion DESACTIVADA, la sonda de mailpit SI conecta (el bloqueo lo causa la proteccion)' ($c.Code -eq 0 -and $c.Output -match 'Execution was successful') (Get-Short $c.Output 200)
}
catch {
    Write-Host "ERROR inesperado: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Add-Result 'ejecucion sin errores inesperados' $false $_.Exception.Message
}
finally {
    # ---------------------------------------------------------------- 6. limpieza y prueba de que la instalacion real no se toco
    Write-Step '6/6 Limpieza del proyecto desechable'
    if ($KeepRunning) {
        Write-Host "(-KeepRunning: el proyecto '$Project' sigue activo; eliminalo con: .\scripts\clean-install-test.ps1 -Teardown)"
    }
    else {
        try {
            $left = Remove-Disposable
            Add-Result "el proyecto desechable se elimina por completo (volumenes restantes: $left)" ($left -eq 0) ''
        }
        catch { Add-Result 'limpieza del proyecto desechable' $false $_.Exception.Message }
    }
    $realVolumesAfter = @(Get-Docker @('volume', 'ls', '--filter', "label=com.docker.compose.project=$RealName", '--format', '{{.Name}}') | Sort-Object)
    Add-Result 'TU instalacion real conserva sus volumenes (no se borro nada)' (($realVolumesBefore -join ',') -eq ($realVolumesAfter -join ',') -and $realVolumesAfter.Count -ge 2) "antes=$($realVolumesBefore -join ',') despues=$($realVolumesAfter -join ',')"
    try {
        $after = [int]((& docker exec "$RealName-postgres-1" psql -U tickets -d tickets -tAc 'select count(*) from tickets_ticket' 2>$null) -join '').Trim()
        Add-Result "TU instalacion real conserva sus datos (tickets: antes=$realTicketsBefore, despues=$after)" ($null -ne $realTicketsBefore -and $after -ge $realTicketsBefore) ''
    }
    catch { Add-Result 'comprobar los datos de tu instalacion real' $false $_.Exception.Message }
}

$failed = @($results | Where-Object { -not $_.Ok }).Count
Write-Host ''
Write-Host ("== Resultado: {0} comprobaciones, {1} correctas, {2} fallidas  (duracion {3:N1} min)" -f $results.Count, ($results.Count - $failed), $failed, ((Get-Date) - $started).TotalMinutes)
exit ([int]($failed -gt 0))
