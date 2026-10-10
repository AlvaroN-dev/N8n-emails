<#
.SYNOPSIS
    T20: escanea en busca de secretos los archivos que ENTRARIAN en Git (rastreados o sin rastrear y no ignorados).

.DESCRIPTION
    1. Lista los archivos con `git ls-files --cached --others --exclude-standard` (lo que `git add -A` anadiria).
    2. Busca los VALORES REALES de los secretos de tu .env (claves, tokens, contrasenas) y patrones tipicos
       (claves de Google/Gemini, claves privadas, cabeceras Authorization, secuencias hexadecimales de 64 caracteres).
    3. Comprueba que .env esta ignorado y que ningun .env* salvo .env.example esta rastreado.
    Nunca imprime el valor encontrado: solo archivo, linea, tipo y longitud. Termina con codigo 1 si hay hallazgos.

.EXAMPLE
    .\scripts\scan-secrets.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$findings = New-Object System.Collections.Generic.List[string]
function Add-Finding([string]$Text) { $findings.Add($Text); Write-Host ("HALLAZGO  {0}" -f $Text) -ForegroundColor Red }

# --- 1. archivos que entrarian en Git ---
$previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $files = @(& git ls-files --cached --others --exclude-standard 2>$null) } finally { $ErrorActionPreference = $previous }
if ($files.Count -eq 0) { throw 'git ls-files no devolvio archivos (es un repositorio git?)' }
Write-Host ("== Archivos que entrarian en Git: {0}" -f $files.Count)

# --- 2. valores reales de los secretos del .env ---
$secrets = @{}
$envPath = Join-Path $root '.env'
if (Test-Path -LiteralPath $envPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($envPath)) {
        if ($line -match '^([A-Z][A-Z0-9_]*(KEY|TOKEN|PASSWORD|SECRET)[A-Z0-9_]*)=(.{16,})$') { $secrets[$Matches[1]] = $Matches[3].Trim() }
    }
}
Write-Host ("== Secretos del .env que se buscan literalmente: {0} ({1})" -f $secrets.Count, (($secrets.Keys | Sort-Object) -join ', '))

$patterns = @(
    @{ Name = 'clave de Google/Gemini (AIza...)';       Regex = 'AIza[0-9A-Za-z_\-]{35}' },
    @{ Name = 'clave de Google con prefijo AQ.';        Regex = 'AQ\.[A-Za-z0-9_\-]{30,}' },
    @{ Name = 'clave privada PEM';                      Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'cabecera Authorization con token';       Regex = '(?i)authorization:\s*bearer\s+[A-Za-z0-9._\-]{20,}' },
    # Los resumenes de imagenes Docker (sha256:...) tienen esta forma y NO son secretos: se excluyen explicitamente.
    @{ Name = 'cadena hexadecimal de 64 caracteres';    Regex = '(?<![0-9a-fA-F])(?<!sha256:)[0-9a-f]{64}(?![0-9a-fA-F])' }
)
$skipExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.gz', '.woff', '.woff2')

foreach ($rel in $files) {
    $full = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    if ($skipExt -contains [System.IO.Path]::GetExtension($rel).ToLower()) { continue }
    $info = Get-Item -LiteralPath $full
    if ($info.Length -gt 3MB) { continue }
    # Lectura con acceso compartido: un archivo que otro proceso esta escribiendo (p. ej. evidencia en curso) no debe romper el escaneo.
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $reader = New-Object System.IO.StreamReader($stream); $lines = $reader.ReadToEnd() -split "`r?`n" }
    finally { $stream.Dispose() }
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        foreach ($name in $secrets.Keys) {
            if ($l.Contains($secrets[$name])) { Add-Finding ("{0}:{1}  valor real de {2} (longitud {3})" -f $rel, ($i + 1), $name, $secrets[$name].Length) }
        }
        foreach ($p in $patterns) {
            $m = [regex]::Match($l, $p.Regex)
            if ($m.Success) { Add-Finding ("{0}:{1}  patron '{2}' (longitud {3})" -f $rel, ($i + 1), $p.Name, $m.Value.Length) }
        }
    }
}

# --- 3. higiene de los .env ---
$previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { & git check-ignore -q .env 2>$null; $envIgnored = ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $previous }
if (-not $envIgnored) { Add-Finding '.env NO esta ignorado por git' }
foreach ($f in $files) {
    if ($f -match '(^|/)\.env' -and $f -ne '.env.example') { Add-Finding "archivo de entorno entraria en Git: $f" }
    if ($f -match '(^|/)n8n/credentials/generated/') { Add-Finding "credenciales generadas entrarian en Git: $f" }
    if ($f -match '\.bak(-|$)') { Add-Finding "copia de seguridad entraria en Git: $f" }
}
if ($files -notcontains '.env.example') { Add-Finding '.env.example no esta entre los archivos de Git' }

Write-Host ''
if ($findings.Count -eq 0) {
    Write-Host ("RESULTADO: OK. {0} archivos revisados, 0 hallazgos." -f $files.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("RESULTADO: {0} hallazgo(s)." -f $findings.Count) -ForegroundColor Red
exit 1
