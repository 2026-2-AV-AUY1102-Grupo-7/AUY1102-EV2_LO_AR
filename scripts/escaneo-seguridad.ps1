<#
.SYNOPSIS
  Escaneo de seguridad del REPOSITORIO COMPLETO (Snyk + npm audit) - EV2 AUY1102, Albert (Snyk).

.DESCRIPTION
  Ejecuta los mismos escaneos antes y despues de la remediacion para comparar:
    1. npm audit                       -> todas las dependencias de package-lock.json
    2. snyk test --all-projects        -> Snyk Open Source, todos los manifiestos del repo
    3. snyk code test                  -> Snyk Code (SAST), todo el codigo fuente
    4. snyk iac test                   -> Snyk IaC, archivos de infraestructura del repo
    5. snyk container test             -> Snyk Container, imagen del FROM del Dockerfile (sin Docker Desktop)
  Guarda los reportes en evidencias/snyk/<etapa>/:
    - un .txt (salida legible) y un .json por herramienta
    - hallazgos-completos.txt : lista de TODOS los hallazgos unicos
    - resumen.txt             : totales por severidad + estado de los 4 hallazgos de Albert

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\escaneo-seguridad.ps1 -Etapa antes
  powershell -ExecutionPolicy Bypass -File scripts\escaneo-seguridad.ps1 -Etapa despues
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('antes', 'despues')]
  [string]$Etapa
)

$ErrorActionPreference = 'Continue'

# PATH actualizado (Node, npm global y Snyk)
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
            (Join-Path $env:APPDATA 'npm')

$repo   = Split-Path -Parent $PSScriptRoot
$salida = Join-Path $repo "evidencias\snyk\$Etapa"
New-Item -ItemType Directory -Force -Path $salida | Out-Null
Set-Location $repo

function Titulo($texto) { Write-Host ''; Write-Host "==> $texto" -ForegroundColor Cyan }
function Ruta($nombre) { Join-Path $salida $nombre }
function Leer-Json($archivo) {
  if (-not (Test-Path $archivo)) { return $null }
  $raw = Get-Content $archivo -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return $raw | ConvertFrom-Json } catch { return $null }
}
function Motivo($txt) {
  $l = @(Get-Content $txt -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
  if ($l.Count -eq 0) { return 'sin resultados' }
  return ($l[0] -replace '^\s*ERROR\s*', '').Trim()
}
function Nuevo-Conteo { [ordered]@{ critical = 0; high = 0; medium = 0; low = 0; total = 0; ok = $true } }

# Lista unica de hallazgos de un JSON de Snyk Open Source / Container
function Hallazgos-Snyk($json) {
  $lista = @()
  if ($null -eq $json) { return $lista }
  $vulns = @($json | ForEach-Object { $_.vulnerabilities }) | Where-Object { $_ }
  foreach ($v in ($vulns | Sort-Object id -Unique)) {
    $lista += [pscustomobject]@{
      severidad = $v.severity
      id        = $v.id
      titulo    = $v.title
      paquete   = "$($v.packageName)@$($v.version)"
      via       = (@($v.from) | Select-Object -Skip 1 -First 1)
    }
  }
  return $lista
}

function Contar($lista, $disponible) {
  $c = Nuevo-Conteo
  $c.ok = $disponible
  foreach ($h in $lista) { if ($c.Contains($h.severidad)) { $c[$h.severidad]++ } }
  $c.total = @($lista).Count
  return $c
}

$inicio = Get-Date
$rama   = git rev-parse --abbrev-ref HEAD
$commit = git rev-parse --short HEAD
Write-Host "=== Escaneo de seguridad (repositorio completo) - etapa: $($Etapa.ToUpper()) ===" -ForegroundColor Yellow
Write-Host "Repositorio : $repo"
Write-Host "Rama        : $rama  (commit $commit)"
Write-Host "Fecha       : $($inicio.ToString('yyyy-MM-dd HH:mm:ss'))"

# 1. npm audit -------------------------------------------------------------
Titulo '1/5 npm audit (todas las dependencias)'
& npm.cmd audit | Out-File -Encoding utf8 (Ruta 'npm-audit.txt')
& npm.cmd audit --json | Out-File -Encoding utf8 (Ruta 'npm-audit.json')
$auditJson = Leer-Json (Ruta 'npm-audit.json')
$audit = Nuevo-Conteo
$hNpm = @()
if ($auditJson) {
  $m = $auditJson.metadata.vulnerabilities
  $audit.critical = $m.critical; $audit.high = $m.high; $audit.medium = $m.moderate
  $audit.low = $m.low; $audit.total = $m.total
  foreach ($p in $auditJson.vulnerabilities.PSObject.Properties) {
    $hNpm += [pscustomobject]@{ severidad = $p.Value.severity; id = '-'; titulo = 'npm audit'; paquete = "$($p.Name) $($p.Value.range)"; via = '' }
  }
} else { $audit.ok = $false }
Write-Host "  listo -> npm-audit.txt / npm-audit.json"

# 2. Snyk Open Source --------------------------------------------------------
Titulo '2/5 snyk test --all-projects (Snyk Open Source)'
$fDeps = Ruta 'snyk-open-source.json'
& snyk.cmd test --all-projects --json-file-output="$fDeps" | Out-File -Encoding utf8 (Ruta 'snyk-open-source.txt')
$depsJson = Leer-Json $fDeps
$hDeps = Hallazgos-Snyk $depsJson
$deps = Contar $hDeps ($null -ne $depsJson)
Write-Host "  listo -> snyk-open-source.txt / snyk-open-source.json"

# 3. Snyk Code (SAST) --------------------------------------------------------
Titulo '3/5 snyk code test (Snyk Code - codigo fuente)'
$fCode = Ruta 'snyk-code.json'
& snyk.cmd code test --json-file-output="$fCode" | Out-File -Encoding utf8 (Ruta 'snyk-code.txt')
$codeJson = Leer-Json $fCode
$hCode = @()
if ($codeJson) {
  $reglas = @{}
  foreach ($r in @($codeJson.runs[0].tool.driver.rules)) { $reglas[$r.id] = $r.shortDescription.text }
  foreach ($r in @($codeJson.runs[0].results)) {
    $sev = switch ($r.level) { 'error' { 'high' } 'warning' { 'medium' } default { 'low' } }
    $loc = $r.locations[0].physicalLocation
    $hCode += [pscustomobject]@{
      severidad = $sev; id = $r.ruleId; titulo = $reglas[$r.ruleId]
      paquete = "$($loc.artifactLocation.uri):$($loc.region.startLine)"; via = ''
    }
  }
}
$code = Contar $hCode ($null -ne $codeJson)
if (-not $code.ok) { Write-Host "  aviso: $(Motivo (Ruta 'snyk-code.txt')) (ver snyk-code.txt)" -ForegroundColor DarkYellow }
else { Write-Host "  listo -> snyk-code.txt / snyk-code.json" }

# 4. Snyk IaC ----------------------------------------------------------------
Titulo '4/5 snyk iac test (Snyk IaC)'
$fIac = Ruta 'snyk-iac.json'
& snyk.cmd iac test --json-file-output="$fIac" | Out-File -Encoding utf8 (Ruta 'snyk-iac.txt')
$iacJson = Leer-Json $fIac
$hIac = @()
if ($iacJson) {
  foreach ($f in @($iacJson)) {
    foreach ($i in @($f.infrastructureAsCodeIssues)) {
      if ($i) { $hIac += [pscustomobject]@{ severidad = $i.severity; id = $i.id; titulo = $i.title; paquete = $f.targetFile; via = '' } }
    }
  }
}
$iac = Contar $hIac ($null -ne $iacJson)
if (-not $iac.ok) { Write-Host "  aviso: $(Motivo (Ruta 'snyk-iac.txt')) - el repo no tiene Terraform/Kubernetes/CloudFormation (ver snyk-iac.txt)" -ForegroundColor DarkYellow }
else { Write-Host "  listo -> snyk-iac.txt / snyk-iac.json" }

# 5. Snyk Container ----------------------------------------------------------
# Snyk descarga la imagen base del FROM directamente desde Docker Hub (no requiere Docker Desktop),
# igual que el proyecto "Dockerfile" del panel web de Snyk.
$from = (Get-Content (Join-Path $repo 'Dockerfile') | Where-Object { $_ -match '^\s*FROM\s+' } | Select-Object -Last 1) -replace '^\s*FROM\s+(\S+).*$', '$1'
Titulo "5/5 snyk container test (Snyk Container - imagen del Dockerfile: $from)"
$fCont = Ruta 'snyk-container.json'
& snyk.cmd container test $from --file=Dockerfile --exclude-app-vulns --json-file-output="$fCont" |
  Out-File -Encoding utf8 (Ruta 'snyk-container.txt')
$contJson = Leer-Json $fCont
$hCont = Hallazgos-Snyk $contJson
$cont = Contar $hCont ($null -ne $contJson)
Write-Host "  listo -> snyk-container.txt / snyk-container.json"

# Lista completa de hallazgos ------------------------------------------------
$orden = @{ critical = 0; high = 1; medium = 2; moderate = 2; low = 3; info = 4 }
$det = @("HALLAZGOS COMPLETOS - etapa $($Etapa.ToUpper()) - $($inicio.ToString('yyyy-MM-dd HH:mm')) - rama $rama ($commit)", '')
foreach ($grupo in @(
    @{ n = 'Snyk Open Source (dependencias)'; l = $hDeps },
    @{ n = 'Snyk Code (codigo fuente)';       l = $hCode },
    @{ n = 'Snyk IaC';                        l = $hIac },
    @{ n = 'Snyk Container (imagen Docker)';  l = $hCont },
    @{ n = 'npm audit (paquetes afectados)';  l = $hNpm })) {
  $det += "### $($grupo.n): $(@($grupo.l).Count)"
  foreach ($h in (@($grupo.l) | Sort-Object { $orden[$_.severidad] })) {
    $extra = ''
    if ($h.via) { $extra = "  (via $($h.via))" }
    $det += ('  [{0,-8}] {1,-34} {2} | {3}{4}' -f $h.severidad.ToUpper(), $h.id, $h.titulo, $h.paquete, $extra)
  }
  $det += ''
}
$det | Out-File -Encoding utf8 (Ruta 'hallazgos-completos.txt')

# Resumen --------------------------------------------------------------------
$idsCont  = @($hCont | ForEach-Object { $_.id })
$nChokidar = @($hDeps | Where-Object { $_.via -match '^chokidar@' }).Count
$imagenBase = @($contJson | ForEach-Object { $_.docker.baseImage }) | Select-Object -First 1
$chokidarVer = (Get-Content (Join-Path $repo 'package.json') -Raw | ConvertFrom-Json).dependencies.chokidar

$asignados = @(
  @{ n = 1; desc = 'node CVE-2025-55131 (Critical)'; ok = -not ($idsCont -contains 'SNYK-UPSTREAM-NODE-14928492') },
  @{ n = 2; desc = 'openssl CVE-2023-2650 (Medium)'; ok = -not ($idsCont -contains 'SNYK-ALPINE316-OPENSSL-5661567') },
  @{ n = 3; desc = 'openssl CVE-2023-5678 (Medium)'; ok = -not ($idsCont -contains 'SNYK-ALPINE316-OPENSSL-6069876') },
  @{ n = 4; desc = "chokidar $chokidarVer ($nChokidar vulns transitivas)"; ok = ($nChokidar -eq 0) }
)

function Fila($nombre, $c) {
  if (-not $c.ok) { return ('{0,-32} {1}' -f $nombre, '   no aplica / no disponible (ver aviso)') }
  return ('{0,-32} {1,8} {2,5} {3,7} {4,4} {5,6}' -f $nombre, $c.critical, $c.high, $c.medium, $c.low, $c.total)
}

$lineas = @()
$lineas += "================ RESUMEN REPO COMPLETO - ETAPA $($Etapa.ToUpper()) ================"
$lineas += "Fecha: $($inicio.ToString('yyyy-MM-dd HH:mm'))   Rama: $rama ($commit)"
$lineas += "Imagen base: $imagenBase"
$lineas += ''
$lineas += ('{0,-32} {1,8} {2,5} {3,7} {4,4} {5,6}' -f 'Herramienta', 'Critical', 'High', 'Medium', 'Low', 'Total')
$lineas += Fila 'npm audit' $audit
$lineas += Fila 'Snyk Open Source (deps)' $deps
$lineas += Fila 'Snyk Code (codigo)' $code
$lineas += Fila 'Snyk IaC' $iac
$lineas += Fila 'Snyk Container (Dockerfile)' $cont
$lineas += ''
$lineas += 'Hallazgos asignados a Albert (remediacion):'
foreach ($h in $asignados) {
  $estado = 'PRESENTE'
  if ($h.ok) { $estado = 'CORREGIDO' }
  $lineas += ('  {0}. {1,-50} {2}' -f $h.n, $h.desc, $estado)
}
$lineas += '========================================================================'

$lineas | Out-File -Encoding utf8 (Ruta 'resumen.txt')
Write-Host ''
foreach ($l in $lineas) {
  $color = 'White'
  if ($l -match 'PRESENTE') { $color = 'Red' }
  elseif ($l -match 'CORREGIDO') { $color = 'Green' }
  elseif ($l -match '^=') { $color = 'Yellow' }
  Write-Host $l -ForegroundColor $color
}
Write-Host "Detalle de todos los hallazgos: $(Ruta 'hallazgos-completos.txt')"
Write-Host "Reportes en: $salida"
