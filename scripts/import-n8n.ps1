<#
.SYNOPSIS
    Importa credenciales y workflows en n8n, publica los que tienen webhook y reinicia n8n.

.DESCRIPTION
    1. Genera las credenciales a partir de n8n/credentials/*.template.json sustituyendo ${VARIABLE}
       con los valores de .env (los secretos nunca estan en los archivos versionados). Una plantilla
       cuyas variables esten vacias se omite (p. ej. Gemini sin clave).
    2. Importa credenciales y workflows con el CLI de n8n. Es idempotente: reimportar actualiza por id.
    3. Publica los workflows con webhook (n8n 2.x: publish:workflow) y reinicia n8n, porque los
       cambios hechos por CLI solo se aplican tras reiniciar.
    El archivo temporal con secretos se borra siempre al terminar.

.EXAMPLE
    .\scripts\import-n8n.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# --- .env ---
# TT_ENV_FILE permite apuntar a otro entorno (por defecto .env), p. ej. la prueba de instalacion limpia.
$envName = if ($env:TT_ENV_FILE) { $env:TT_ENV_FILE } else { '.env' }
$envFile = Join-Path $root $envName
if (-not (Test-Path -LiteralPath $envFile)) { throw "No existe $envName. Ejecuta .\scripts\setup.ps1" }
$envVars = @{}
foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
    if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') { $envVars[$Matches[1]] = $Matches[2].Trim() }
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    # docker compose escribe su progreso en stderr. En Windows PowerShell 5.1, con 'Stop', eso se convertiria
    # en un error terminante aunque el comando vaya bien: el exito se decide SOLO por el codigo de salida.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & docker compose @ComposeArgs 2>&1 | ForEach-Object { "$_" } | Out-Host }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "docker compose $($ComposeArgs -join ' ') termino con codigo $LASTEXITCODE" }
}

function Get-N8nHealth {
    return ((& docker compose ps n8n --format '{{.Health}}') -join '').Trim()
}

function Wait-N8nHealthy {
    param([int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-N8nHealth) -eq 'healthy') { return }
        Start-Sleep -Seconds 3
    }
    throw "n8n no llego a estado healthy en $TimeoutSeconds s"
}

if ((Get-N8nHealth) -ne 'healthy') { throw 'n8n no esta healthy. Ejecuta: docker compose up -d --wait' }

# --- 1. Credenciales: plantilla -> JSON con secretos (archivo temporal ignorado por Git) ---
$credDir  = Join-Path $root 'n8n\credentials'
$genDir   = Join-Path $credDir 'generated'
$genFile  = Join-Path $genDir 'credentials.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Valores por defecto de las variables que seleccionan plantillas con "_onlyIf".
$defaults = @{ LLM_PROVIDER = 'mock' }
function Get-Setting([string]$Name) {
    if ($envVars.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($envVars[$Name])) { return $envVars[$Name] }
    if ($defaults.ContainsKey($Name)) { return $defaults[$Name] }
    return ''
}

$rendered = New-Object System.Collections.Generic.List[string]
foreach ($tpl in (Get-ChildItem -LiteralPath $credDir -Filter '*.template.json' | Sort-Object Name)) {
    $text = [System.IO.File]::ReadAllText($tpl.FullName, $utf8NoBom)

    # "_onlyIf": "VARIABLE=valor" -> la plantilla solo se usa si .env (o su valor por defecto) coincide.
    $probe = $text | ConvertFrom-Json
    if ($probe.PSObject.Properties.Name -contains '_onlyIf') {
        $cond = ([string]$probe._onlyIf) -split '=', 2
        if ((Get-Setting $cond[0]) -ne $cond[1]) { continue }
        Write-Host ("Credencial seleccionada por {0}={1}: {2}" -f $cond[0], $cond[1], $tpl.Name)
        $text = [regex]::Replace($text, '(?m)^\s*"_onlyIf"\s*:\s*"[^"]*"\s*,\s*\r?\n', '')
    }

    $missing = @()
    foreach ($m in [regex]::Matches($text, '\$\{([A-Z][A-Z0-9_]*)\}')) {
        $name = $m.Groups[1].Value
        if (-not $envVars.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($envVars[$name])) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        Write-Host ("Credencial omitida ({0}): falta {1} en .env" -f $tpl.Name, (($missing | Select-Object -Unique) -join ', '))
        continue
    }
    $text = [regex]::Replace($text, '\$\{([A-Z][A-Z0-9_]*)\}', {
        param($m)
        $escaped = ConvertTo-Json -InputObject $envVars[$m.Groups[1].Value] -Compress   # escapado JSON seguro
        return $escaped.Substring(1, $escaped.Length - 2)
    })
    $null = $text | ConvertFrom-Json   # valida que el JSON resultante es correcto
    $rendered.Add($text.Trim())
}
if ($rendered.Count -eq 0) { throw 'No hay credenciales que importar.' }

New-Item -ItemType Directory -Force -Path $genDir | Out-Null
try {
    [System.IO.File]::WriteAllText($genFile, '[' + ($rendered -join ',') + ']', $utf8NoBom)
    Write-Host "== Importando $($rendered.Count) credencial(es)"
    Invoke-Compose @('exec', '-T', 'n8n', 'n8n', 'import:credentials', '--input=/import/credentials/generated/credentials.json')
}
finally {
    if (Test-Path -LiteralPath $genFile) { Remove-Item -LiteralPath $genFile -Force }
}

# --- 2. Workflows ---
Write-Host '== Importando workflows'
Invoke-Compose @('exec', '-T', 'n8n', 'n8n', 'import:workflow', '--separate', '--input=/import/workflows')

# --- 3. Publicar TODOS los workflows ---
# Incluido el de errores (WF3, solo Error Trigger): en n8n 2.x un workflow de errores sin version activa NO se ejecuta
# ("Workflow ... is not active and cannot be executed"), a diferencia de lo que decia la documentacion de 1.x.
$publishedIds = New-Object System.Collections.Generic.List[string]
foreach ($wf in (Get-ChildItem -LiteralPath (Join-Path $root 'n8n\workflows') -Filter '*.json' | Sort-Object Name)) {
    $json = [System.IO.File]::ReadAllText($wf.FullName, $utf8NoBom) | ConvertFrom-Json
    $publishedIds.Add([string]$json.id)
    Write-Host "== Publicando $($wf.Name) (id $($json.id))"
    Invoke-Compose @('exec', '-T', 'n8n', 'n8n', 'publish:workflow', "--id=$($json.id)")
}

# --- 4. Reinicio: los cambios por CLI solo se aplican al reiniciar ---
Write-Host '== Reiniciando n8n'
Invoke-Compose @('restart', 'n8n')
Wait-N8nHealthy

# "healthy" NO basta: n8n sirve webhooks con la version ANTERIOR hasta reconciliar las publicaciones (~15 s tras
# arrancar). Se espera a que la version activa de cada workflow publicado este realmente en marcha.
Write-Host '== Esperando a que las versiones nuevas esten en marcha (n8n reconcilia las publicaciones tras arrancar)'
$deadline = (Get-Date).AddSeconds(120)
$state = ''
while ($true) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $state = (& docker compose exec -T n8n node --no-warnings /import/src/tools/published.js @($publishedIds.ToArray()) 2>&1 | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) { throw "Las versiones publicadas no estan en marcha tras 120 s. Estado: $state" }
    Start-Sleep -Seconds 2
}
Write-Host 'Importacion terminada. n8n esta healthy y las versiones nuevas estan en marcha.'
