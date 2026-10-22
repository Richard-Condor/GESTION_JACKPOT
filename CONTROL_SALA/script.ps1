# ============================================================================
# script.ps1 - ACTUALIZACION API + PANEL (panel de gestion v2)
# v4.6 (2026-10-22): script de UNA subida. Hace SOLO tres cosas:
#   1) FASE A: migra la API a la api_server.nuevo corregida (la del sello
#      de ping: "ultima conexion" = hora del momento si la maquina
#      responde), conservando el nombre de la sala y la IP de cada
#      servidor (logica identica a la probada en las visitas de rescate).
#   2) AVISO OK: manda UNA fila a la hoja de Google con el nombre de la
#      sala, "OK" y la fecha (solo si la migracion se ha hecho y el
#      panel.html de C:\Control es el bueno, SHA256 F7CAAD3C...).
#      Sin OK en la hoja = esa sala no se ha actualizado.
#   3) CIERRE: reinicia la API (matar diferido por WMI, como la v4.4)
#      para que la nueva entre en servicio.
# NO recorre equipos: no hay FASE B ni informe de campana. El panel.html
# nuevo lo copia el propio actualizador como fichero suelto antes de
# ejecutar este script. Pensado para subirlo a CONTROL_SALA junto a la
# api_server.nuevo corregida y el panel.html bueno; cada sala viva lo
# ejecuta una sola vez en su ciclo de 15 min.
# ============================================================================

$ControlPath = "C:\Control"
$LogFile     = Join-Path $ControlPath "campana.log"

# Hoja de Google (la misma del instalador RustDesk) para el aviso OK
$SheetsUrl = "https://script.google.com/macros/s/AKfycbxb415JbG0_-y2hmMtrhGN6nUtAqGGOqV5T33KnNfrbIoi_-e4kq2INHk-PeCDMPD44gw/exec"

function Log-Campana([string]$m) {
    $linea = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    Add-Content -Path $LogFile -Value $linea -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $linea
}

Log-Campana "================ ACTUALIZACION API + PANEL ================"

# ============================================================================
# FASE A - Migracion de la API (la misma logica probada de la v4.5)
# ============================================================================
$script:NombreSala = $null
$script:ApiMigrada  = $false
try {
    $apiActual = Join-Path $ControlPath "api_server.ps1"
    $apiNueva  = Join-Path $ControlPath "api_server.nuevo"
    if ((Test-Path $apiNueva) -and (Test-Path $apiActual)) {
        $viejo = Get-Content $apiActual -Raw -Encoding UTF8
        $mIP   = [regex]::Match($viejo, '(?m)^\$IP_DEL_SERVIDOR\s*=\s*"([^"]*)"')
        $mNom  = [regex]::Match($viejo, '(?m)^\$SALA_NOMBRE\s*=\s*"([^"]*)"')
        if ($mIP.Success -and $mNom.Success -and $mIP.Groups[1].Value -ne "" -and $mNom.Groups[1].Value -ne "") {
            $ipSala = $mIP.Groups[1].Value; $script:NombreSala = $mNom.Groups[1].Value
            $nuevo = Get-Content $apiNueva -Raw -Encoding UTF8
            $nuevo = $nuevo -replace '(?m)^\$IP_DEL_SERVIDOR\s*=.*', "`$IP_DEL_SERVIDOR = `"$ipSala`""
            $nuevo = $nuevo -replace '(?m)^\$SALA_NOMBRE\s*=.*',     "`$SALA_NOMBRE = `"$($script:NombreSala)`""
            if ($nuevo -match [regex]::Escape("`$SALA_NOMBRE = `"$($script:NombreSala)`"")) {
                $respaldo = Join-Path $ControlPath ("api_server.ps1.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
                Copy-Item $apiActual $respaldo -Force -ErrorAction Stop
                [System.IO.File]::WriteAllText($apiActual, $nuevo, (New-Object System.Text.UTF8Encoding($true)))
                $script:ApiMigrada = $true
                Log-Campana "FASE A: API migrada (sala '$($script:NombreSala)', IP $ipSala). Respaldo: $respaldo"
            } else { Log-Campana "FASE A: la inyeccion no caso; API sin tocar." }
        } else { Log-Campana "FASE A: no se pudo leer la identidad del api actual; API sin tocar." }
    } else { Log-Campana "FASE A: omitida (no hay api_server.nuevo o api_server.ps1)." }
    if (-not $script:NombreSala -and (Test-Path $apiActual)) {
        $t = Get-Content $apiActual -Raw -Encoding UTF8
        $mm = [regex]::Match($t, '(?m)^\$SALA_NOMBRE\s*=\s*"([^"]*)"')
        if ($mm.Success) { $script:NombreSala = $mm.Groups[1].Value }
    }
} catch { Log-Campana "FASE A: error: $($_.Exception.Message)" }
if (-not $script:NombreSala) { $script:NombreSala = $env:COMPUTERNAME }

# ============================================================================
# AVISO OK - Una sola fila a la hoja: sala + OK + fecha.
# Solo se manda si la API se ha migrado Y el panel de C:\Control es el
# bueno (SHA256 esperado). Si algo no cuadra, no hay OK: queda en el log.
# ============================================================================
$PanelSHA = "F7CAAD3C0B5ACFF15F1411947D76381D2F33FC89F8EA3A0CF501248B5D699B34"
$panelOk = $false
try {
    $panelPath = Join-Path $ControlPath "panel.html"
    if (Test-Path $panelPath) {
        $h = (Get-FileHash $panelPath -Algorithm SHA256).Hash
        $panelOk = ($h -eq $PanelSHA)
        Log-Campana "PANEL: SHA256 $h (esperado $PanelSHA) - coincide: $panelOk"
    } else { Log-Campana "PANEL: no hay panel.html en C:\Control." }
} catch { Log-Campana "PANEL: no se pudo comprobar el hash: $($_.Exception.Message)" }

if ($script:ApiMigrada -and $panelOk) {
    $payload = "{""nombre"":""$($script:NombreSala -replace '"','')"",""id"":""OK"",""pc"":,usuario:,""fecha"":""$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')""}"
    $enviado = $false
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "application/json")
        $wc.UploadString($SheetsUrl, $payload) | Out-Null
        $enviado = $true
    } catch {}
    if (-not $enviado) {
        try { Invoke-RestMethod -Uri $SheetsUrl -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 15 -UseBasicParsing | Out-Null; $enviado = $true } catch {}
    }
    if ($enviado) { Log-Campana "AVISO OK: enviado a la hoja (sala '$($script:NombreSala)')." }
    else { Log-Campana "AVISO OK: no se pudo enviar a la hoja; la actualizacion local si esta hecha." }
} else {
    Log-Campana "AVISO OK: NO enviado (ApiMigrada=$script:ApiMigrada, PanelOk=$panelOk)."
}

# ============================================================================
# CIERRE v4.4 - Si la FASE A ha migrado la API, reiniciarla para aplicar
# (matar diferido por WMI, fuera del arbol de procesos: el actualizador
# apunta la ejecucion en su manifiesto antes de que la API muera)
# ============================================================================
if ($script:ApiMigrada) {
    try {
        $apiProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "api_server\.ps1" -and $_.ProcessId -ne $PID }
        foreach ($p in $apiProcs) {
            $cmdKill = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Sleep -Seconds 15; Stop-Process -Id $($p.ProcessId) -Force`""
            $resKill = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdKill }
            if ($resKill.ReturnValue -eq 0) {
                Log-Campana "CIERRE: reinicio de la API programado en 15 s (PID $($p.ProcessId)) para aplicar la migracion."
            } else {
                Log-Campana "CIERRE: WMI no pudo programar el reinicio de la API (codigo $($resKill.ReturnValue))."
            }
        }
    } catch { Log-Campana "CIERRE: no se pudo programar el reinicio de la API: $($_.Exception.Message)" }
}

Log-Campana "================ FIN ACTUALIZACION ================"
