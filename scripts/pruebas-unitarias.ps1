<#
.SYNOPSIS
  Parte 1 - EV2 AUY1102: ejecuta las pruebas unitarias existentes y reporta la cobertura.

.DESCRIPTION
  1. Ejecuta todas las pruebas con Jest (+ cobertura).
  2. Muestra por pantalla cada prueba con su estado y, en detalle, las que FALLAN.
  3. Muestra el porcentaje de cobertura global (sentencias, ramas, funciones, lineas)
     y por archivo.
  4. Muestra que parte del codigo NO esta cubierta: lineas y funciones sin probar.
  Guarda la evidencia en evidencias/pruebas/ y el reporte HTML/LCOV en coverage/.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\pruebas-unitarias.ps1
#>
$ErrorActionPreference = 'Continue'

$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
            (Join-Path $env:APPDATA 'npm')

$repo   = Split-Path -Parent $PSScriptRoot
$salida = Join-Path $repo 'evidencias\pruebas'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
Set-Location $repo

function Titulo($texto) { Write-Host ''; Write-Host "==> $texto" -ForegroundColor Cyan }
function Pct($v) { '{0,6:N2}%' -f [double]$v }
function Color-Pct($v) { if ($v -ge 80) { 'Green' } elseif ($v -ge 50) { 'Yellow' } else { 'Red' } }
function Rel($ruta) { $ruta.Replace($repo + '\', '').Replace('\', '/') }

# Convierte una lista de numeros de linea en rangos: 3,4,5,9 -> "3-5, 9"
function Rangos($lineas) {
  $ls = @($lineas | Sort-Object -Unique)
  if ($ls.Count -eq 0) { return '' }
  $partes = @(); $ini = $ls[0]; $ant = $ls[0]
  foreach ($l in ($ls | Select-Object -Skip 1)) {
    if ($l -eq $ant + 1) { $ant = $l; continue }
    if ($ini -eq $ant) { $partes += "$ini" } else { $partes += "$ini-$ant" }
    $ini = $l; $ant = $l
  }
  if ($ini -eq $ant) { $partes += "$ini" } else { $partes += "$ini-$ant" }
  return ($partes -join ', ')
}

$inicio = Get-Date
Write-Host '=== Pruebas unitarias y cobertura - AUY1102 EV2 ===' -ForegroundColor Yellow
Write-Host "Repositorio : $repo"
Write-Host "Rama        : $(git rev-parse --abbrev-ref HEAD)  (commit $(git rev-parse --short HEAD))"
Write-Host "Fecha       : $($inicio.ToString('yyyy-MM-dd HH:mm:ss'))"

if (-not (Test-Path (Join-Path $repo 'node_modules'))) {
  Titulo 'Instalando dependencias (npm ci)'
  & npm.cmd ci --ignore-scripts --no-audit --no-fund | Out-Null
}

# 1. Ejecutar Jest -----------------------------------------------------------
Titulo '1/3 Ejecutando pruebas unitarias (Jest + cobertura)'
$jsonRes = Join-Path $salida 'jest-resultados.json'
$logJest = Join-Path $salida 'jest-salida.txt'
cmd /c "npx.cmd jest --coverage --silent --json --outputFile=`"$jsonRes`" --coverageReporters=text --coverageReporters=json-summary --coverageReporters=json --coverageReporters=lcov --coverageReporters=html > `"$logJest`" 2>&1"
$codigoJest = $LASTEXITCODE
if (-not (Test-Path $jsonRes)) {
  Write-Host '  ERROR: Jest no genero resultados. Revisa evidencias/pruebas/jest-salida.txt' -ForegroundColor Red
  exit 1
}
$res = Get-Content $jsonRes -Raw | ConvertFrom-Json

foreach ($suite in ($res.testResults | Sort-Object name)) {
  $colorSuite = 'Green'; if ($suite.status -ne 'passed') { $colorSuite = 'Red' }
  Write-Host ("  {0}" -f (Rel $suite.name)) -ForegroundColor $colorSuite
  foreach ($t in $suite.assertionResults) {
    if ($t.status -eq 'passed') { Write-Host ("     [OK]    {0}" -f $t.fullName) -ForegroundColor Green }
    elseif ($t.status -eq 'failed') { Write-Host ("     [FALLA] {0}" -f $t.fullName) -ForegroundColor Red }
    else { Write-Host ("     [{0}] {1}" -f $t.status.ToUpper(), $t.fullName) -ForegroundColor DarkYellow }
  }
}

# 2. Pruebas que fallan ------------------------------------------------------
Titulo '2/3 Pruebas que fallan'
$fallidas = @()
foreach ($suite in $res.testResults) {
  foreach ($t in ($suite.assertionResults | Where-Object { $_.status -eq 'failed' })) {
    $fallidas += [pscustomobject]@{ archivo = (Rel $suite.name); prueba = $t.fullName; mensaje = (($t.failureMessages -join "`n") -split "`n" | Select-Object -First 6) -join "`n         " }
  }
  if ($suite.status -eq 'failed' -and @($suite.assertionResults).Count -eq 0) {
    $fallidas += [pscustomobject]@{ archivo = (Rel $suite.name); prueba = '(la suite no pudo ejecutarse)'; mensaje = (($suite.message -split "`n") | Select-Object -First 6) -join "`n         " }
  }
}
if ($fallidas.Count -eq 0) {
  Write-Host '  Ninguna prueba falla.' -ForegroundColor Green
} else {
  foreach ($f in $fallidas) {
    Write-Host ("  [FALLA] {0}" -f $f.prueba) -ForegroundColor Red
    Write-Host ("     archivo: {0}" -f $f.archivo)
    Write-Host ("     motivo : {0}" -f $f.mensaje) -ForegroundColor DarkGray
  }
}

# 3. Cobertura ---------------------------------------------------------------
Titulo '3/3 Cobertura de codigo'
$resumen = Get-Content (Join-Path $repo 'coverage\coverage-summary.json') -Raw | ConvertFrom-Json
$final   = Get-Content (Join-Path $repo 'coverage\coverage-final.json') -Raw | ConvertFrom-Json
$tot = $resumen.total
Write-Host '  Cobertura global:'
foreach ($m in @(@('Sentencias', 'statements'), @('Ramas', 'branches'), @('Funciones', 'functions'), @('Lineas', 'lines'))) {
  $d = $tot.($m[1])
  Write-Host ("     {0,-11}: {1}  ({2}/{3})" -f $m[0], (Pct $d.pct), $d.covered, $d.total) -ForegroundColor (Color-Pct $d.pct)
}

Write-Host ''
Write-Host ('  {0,-52} {1,8} {2,8} {3,8} {4,8}' -f 'Archivo', 'Sent.', 'Ramas', 'Func.', 'Lineas')
$noCubierto = @()
foreach ($p in ($resumen.PSObject.Properties | Where-Object { $_.Name -ne 'total' } | Sort-Object Name)) {
  $d = $p.Value
  Write-Host ('  {0,-52} {1,8} {2,8} {3,8} {4,8}' -f (Rel $p.Name), (Pct $d.statements.pct), (Pct $d.branches.pct), (Pct $d.functions.pct), (Pct $d.lines.pct)) -ForegroundColor (Color-Pct $d.lines.pct)

  $cov = $final.($p.Name)
  if ($null -eq $cov) { continue }
  $lineas = @()
  foreach ($s in $cov.s.PSObject.Properties) {
    if ([int]$s.Value -eq 0) {
      $loc = $cov.statementMap.($s.Name)
      $lineas += $loc.start.line..$loc.end.line
    }
  }
  $fuente = @(Get-Content $p.Name)
  $funciones = @()
  foreach ($f in $cov.f.PSObject.Properties) {
    if ([int]$f.Value -eq 0) {
      $fn = $cov.fnMap.($f.Name)
      $n = [int]$fn.loc.start.line
      $codigo = ''
      if ($n -ge 1 -and $n -le $fuente.Count) { $codigo = $fuente[$n - 1].Trim() }
      if ($codigo.Length -gt 60) { $codigo = $codigo.Substring(0, 57) + '...' }
      $funciones += "L$($n): $codigo"
    }
  }
  $funciones = @($funciones | Sort-Object { [int]($_ -replace '^L(\d+):.*$', '$1') } -Unique)
  if ($lineas.Count -gt 0 -or $funciones.Count -gt 0) {
    $noCubierto += [pscustomobject]@{ archivo = (Rel $p.Name); lineas = (Rangos $lineas); funciones = $funciones }
  }
}

Write-Host ''
Write-Host '  Codigo NO cubierto por pruebas:' -ForegroundColor Yellow
if ($noCubierto.Count -eq 0) {
  Write-Host '     Todo el codigo esta cubierto.' -ForegroundColor Green
} else {
  foreach ($n in $noCubierto) {
    Write-Host ("     {0}" -f $n.archivo) -ForegroundColor Red
    if ($n.lineas)    { Write-Host ("        lineas sin cubrir   : {0}" -f $n.lineas) }
    if ($n.funciones.Count -gt 0) {
      Write-Host '        funciones sin probar:'
      foreach ($fx in $n.funciones) { Write-Host ("          - {0}" -f $fx) -ForegroundColor DarkGray }
    }
  }
}

# Resumen final --------------------------------------------------------------
$lineasRes = @()
$lineasRes += '==================== RESUMEN PRUEBAS UNITARIAS ===================='
$lineasRes += "Fecha: $($inicio.ToString('yyyy-MM-dd HH:mm'))   Rama: $(git rev-parse --abbrev-ref HEAD)"
$lineasRes += ("Suites : {0} total | {1} pasan | {2} fallan" -f $res.numTotalTestSuites, $res.numPassedTestSuites, $res.numFailedTestSuites)
$lineasRes += ("Pruebas: {0} total | {1} pasan | {2} fallan | {3} pendientes" -f $res.numTotalTests, $res.numPassedTests, $res.numFailedTests, $res.numPendingTests)
$lineasRes += ("Cobertura: sentencias {0} | ramas {1} | funciones {2} | lineas {3}" -f (Pct $tot.statements.pct).Trim(), (Pct $tot.branches.pct).Trim(), (Pct $tot.functions.pct).Trim(), (Pct $tot.lines.pct).Trim())
$lineasRes += "Archivos con codigo sin cubrir: $($noCubierto.Count)"
$lineasRes += '==================================================================='
$lineasRes | Out-File -Encoding utf8 (Join-Path $salida 'resumen.txt')
$noCubierto | ForEach-Object { "$($_.archivo)`n  lineas sin cubrir: $($_.lineas)`n  funciones sin probar:`n    " + ($_.funciones -join "`n    ") + "`n" } | Out-File -Encoding utf8 (Join-Path $salida 'codigo-no-cubierto.txt')
$fallidas | Format-List | Out-File -Encoding utf8 (Join-Path $salida 'pruebas-fallidas.txt')

Write-Host ''
foreach ($l in $lineasRes) {
  $c = 'White'
  if ($l -match '^=') { $c = 'Yellow' }
  elseif ($l -match 'fallan' -and $res.numFailedTests -gt 0) { $c = 'Red' }
  Write-Host $l -ForegroundColor $c
}
Write-Host "Evidencia: $salida"
Write-Host "Reporte HTML de cobertura: $(Join-Path $repo 'coverage\lcov-report\index.html')"

exit $codigoJest
