# =====================================================================
#  instalar_fase2_v3.ps1 - FASE 2 en UNA sala, version definitiva:
#    1) Reinstala el api_server desde api_server.nuevo (con la
#       identidad de ESTA sala leida del api instalado) y lo rearranca.
#    2) Comprueba que el panel.html nuevo esta en C:\Control.
#    3) Copia el control_kiosk.ps1 nuevo a los miniPC de los registros
#       (C:\Control\kiosks\*.json) con las credenciales de la flota:
#       net use con User1 y, si falla, User2 (leidas del api instalado,
#       nunca se imprimen). Verifica cada copia por huella remota.
#  Sin reinicios de miniPC: el control nuevo entra en el siguiente
#  latido de cada maquina.
#
#  Ejecutar COMO ADMINISTRADOR en el SERVIDOR de la sala, con estos
#  ficheros en la MISMA carpeta que el script:
#      api_server.nuevo   panel.html   control_kiosk.ps1
# =====================================================================
$ErrorActionPreference = 'Continue'
$Aqui    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Control = 'C:\Control'
$H_API     = 'EE53223C244EBD380BF0A72E868F05F07CFB2BD81D31B5AE9770B7C5AB93E46D'
$H_PANEL   = '4CA779310067D2BCE416A1429AA8CF30E77B11F75740C103B19B487548F8F0B6'
$H_CONTROL = '1403F582C6F8E4C433B72711AD20D29EC0C5C56C7523D7B9E5AC4F9E921C24BF'

function Parar($m) { Write-Host "`nPARO: $m" -ForegroundColor Red; exit 1 }
function Huella($p) { (Get-FileHash $p -Algorithm SHA256).Hash }

Write-Host '== INSTALADOR FASE 2 v3 ==' -ForegroundColor Cyan

# --- 0) ficheros y huellas -------------------------------------------
foreach ($par in @(@('api_server.nuevo', $H_API), @('panel.html', $H_PANEL), @('control_kiosk.ps1', $H_CONTROL))) {
    $p = Join-Path $Aqui $par[0]
    if (-not (Test-Path $p)) { Parar "falta $($par[0]) junto al script." }
    if ((Huella $p) -ne $par[1]) { Parar "la huella de $($par[0]) no cuadra. No toco nada." }
}
$apiInstalado = Join-Path $Control 'api_server.ps1'
if (-not (Test-Path $apiInstalado)) { Parar 'no encuentro el api_server.ps1 instalado en C:\Control.' }
Write-Host '0) Huellas OK.' -ForegroundColor Green

# --- datos del api instalado: identidad y credenciales (no se imprimen)
$apiTxt = Get-Content $apiInstalado -Raw -Encoding UTF8
function Dato($n) {
    $m = [regex]::Match($apiTxt, "(?m)^\s*\`$$n\s*=\s*[""']([^""']*)[""']")
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}
$ipSala = Dato 'IP_DEL_SERVIDOR'; $nombreSala = Dato 'SALA_NOMBRE'
$U1 = Dato 'User1'; $P1 = Dato 'Pass1'; $U2 = Dato 'User2'; $P2 = Dato 'Pass2'
if (-not ($ipSala -and $nombreSala)) { Parar 'no leo la identidad de la sala del api instalado.' }
if (-not ($U1 -and $P1)) { Parar 'no leo User1/Pass1 del api instalado.' }
Write-Host "   Sala: $nombreSala ($ipSala)"

# --- 1) reinstalar el api ---------------------------------------------
$lineas = Get-Content (Join-Path $Aqui 'api_server.nuevo') -Encoding UTF8
$lineas = $lineas | ForEach-Object {
    if ($_ -match '^\$IP_DEL_SERVIDOR\s*=') { "`$IP_DEL_SERVIDOR = `"$ipSala`"" }
    elseif ($_ -match '^\$SALA_NOMBRE\s*=') { "`$SALA_NOMBRE = `"$nombreSala`"" }
    else { $_ }
}
$bakApi = "$apiInstalado.bak-fase2"
if (-not (Test-Path $bakApi)) { Copy-Item $apiInstalado $bakApi -Force }
Set-Content -Path $apiInstalado -Value $lineas -Encoding UTF8
Write-Host '1) api_server.ps1 reinstalado con la identidad de la sala.' -ForegroundColor Green

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'api_server\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$apiOk = $false
foreach ($i in 1..30) {
    Start-Sleep -Seconds 2
    try { $null = Invoke-WebRequest 'http://127.0.0.1:5005/' -UseBasicParsing -TimeoutSec 3; $apiOk = $true; break } catch { if ($_.Exception.Response) { $apiOk = $true; break } }
}
if ($apiOk) { Write-Host '   API respondiendo en :5005.' -ForegroundColor Green }
else { Write-Host '   AVISO: la API aun no responde (a veces tarda mas de 60 s); sigo con el control.' -ForegroundColor Yellow }

# --- 2) panel -----------------------------------------------------------
$panelDst = Join-Path $Control 'panel.html'
$panelSrc = Join-Path $Aqui 'panel.html'
if ((Resolve-Path $panelSrc).Path -ne $panelDst) {
    if ((Test-Path $panelDst) -and -not (Test-Path "$panelDst.bak-fase2")) { Copy-Item $panelDst "$panelDst.bak-fase2" -Force }
    Copy-Item $panelSrc $panelDst -Force
}
if ((Huella $panelDst) -eq $H_PANEL) { Write-Host '2) panel.html nuevo confirmado en C:\Control.' -ForegroundColor Green }
else { Write-Host '2) AVISO: el panel de C:\Control no tiene la huella nueva.' -ForegroundColor Yellow }

# --- 3) copia del control a los miniPC de los registros -----------------
$origen = Join-Path $Aqui 'control_kiosk.ps1'
$MisIPs = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
$ips = Get-ChildItem (Join-Path $Control 'kiosks') -Filter '*.json' |
       ForEach-Object { ($_.BaseName -split '_')[0] } | Sort-Object -Unique
Write-Host ("3) MiniPC de la sala: " + $ips.Count)
$okList = @(); $yaList = @(); $sinRed = @(); $sinAcceso = @(); $errores = @()
foreach ($ip in $ips) {
    $destino = "\\$ip\C$\Kiosk\control_kiosk.ps1"
    if ($MisIPs -contains $ip) {
        Copy-Item $origen 'C:\Kiosk\control_kiosk.ps1' -Force -ErrorAction SilentlyContinue
        Write-Host "   $ip  este servidor: copiado en local" -ForegroundColor Green
        $okList += $ip; continue
    }
    if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "   $ip  SIN RED" -ForegroundColor Yellow; $sinRed += $ip; continue
    }
    $conectado = $false
    foreach ($par in @(@($U1, $P1), @($U2, $P2))) {
        if (-not $par[0]) { continue }
        net use "\\$ip\C$" /delete /y 2>&1 | Out-Null
        net use "\\$ip\C$" /user:$($par[0]) $($par[1]) 2>&1 | Out-Null
        if (Test-Path "\\$ip\C$\Kiosk") { $conectado = $true; break }
    }
    if (-not $conectado) {
        Write-Host "   $ip  SIN ACCESO (net use rechazado con las dos credenciales)" -ForegroundColor Red
        $sinAcceso += $ip; continue
    }
    try {
        $hRemota = $null
        if (Test-Path $destino) { $hRemota = Huella $destino }
        if ($hRemota -eq $H_CONTROL) {
            Write-Host "   $ip  ya tenia el de la fase 2" -ForegroundColor DarkGray
            $yaList += $ip
        } else {
            if ((Test-Path $destino) -and -not (Test-Path "$destino.bak-fase2")) { Copy-Item $destino "$destino.bak-fase2" -Force }
            Copy-Item $origen $destino -Force -ErrorAction Stop
            if ((Huella $destino) -eq $H_CONTROL) { Write-Host "   $ip  copiado y verificado" -ForegroundColor Green; $okList += $ip }
            else { Write-Host "   $ip  copiado pero la huella no cuadra" -ForegroundColor Red; $errores += $ip }
        }
    } catch {
        Write-Host "   $ip  ERROR: $($_.Exception.Message)" -ForegroundColor Red; $errores += $ip
    }
    net use "\\$ip\C$" /delete /y 2>&1 | Out-Null
}

Write-Host "`n== RESULTADO ==" -ForegroundColor Cyan
Write-Host ("Control fase 2: copiados {0} · ya lo tenian {1} · total {2} de {3}" -f $okList.Count, $yaList.Count, ($okList.Count + $yaList.Count), $ips.Count)
if ($sinRed.Count)    { Write-Host ("Sin red:     " + ($sinRed -join ', ')) -ForegroundColor Yellow }
if ($sinAcceso.Count) { Write-Host ("Sin acceso:  " + ($sinAcceso -join ', ')) -ForegroundColor Red }
if ($errores.Count)   { Write-Host ("Con error:   " + ($errores -join ', ')) -ForegroundColor Red }
Write-Host 'El control nuevo entra solo en el siguiente latido de cada maquina.'
