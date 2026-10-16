# ============================================================================
# CONTROL_KIOSK.PS1 - CHECK-IN Y EJECUCION DE COMANDOS REMOTOS (MULTIPUESTO)
# ============================================================================
param([string]$ServerIP, [string]$ServerUser, [string]$ServerPass, [switch]$SoloCheckin, [switch]$Latido)

$miID = $PID
$otrosControl = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%control_kiosk.ps1%'" | Where-Object { $_.ProcessId -ne $miID }
# v2: el latido convive con las pasadas completas: un latido nunca bloquea un
# comando ni una pasada completa bloquea al latido; solo se evita que haya
# dos pasadas del MISMO tipo a la vez.
if ($Latido) {
    if ($otrosControl | Where-Object { $_.CommandLine -match '-Latido' }) { exit 0 }
} else {
    if ($otrosControl | Where-Object { $_.CommandLine -notmatch '-Latido' }) { exit 0 }
}

$KioskRoot    = "C:\Kiosk"
$TargetFolder = "$KioskRoot\01.CalimaJackpot"
$LogDir       = "$KioskRoot\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile      = "$LogDir\control_kiosk.log"

if (-not $ServerIP) {
    $batFile = "$KioskRoot\inicio.bat"
    if (Test-Path $batFile) {
        $batContent = Get-Content $batFile -Raw
        if ($batContent -match 'set\s+"UPDATE_SERVER=([^"]+)"') { $ServerIP = $matches[1] }
        if ($batContent -match 'set\s+"UPDATE_USER=([^"]+)"')   { $ServerUser = $matches[1] }
        if ($batContent -match 'set\s+"UPDATE_PASS=([^"]+)"')   { $ServerPass = $matches[1] }
    }
}

$ApiBase = "http://${ServerIP}:8080"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$env:COMPUTERNAME] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

Write-Log "=== CONTROL_KIOSK INICIADO ($(if ($Latido) { 'latido' } elseif ($SoloCheckin) { 'solo-checkin' } else { 'completo' })) ===" "Cyan"

function Get-MatriculaLocal {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try {
        $c = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ($c -match '"matricula"\s*:\s*"([^"]*)"') { return $matches[1] } 
        else { return "" }
    } catch { return "" }
}

function Get-SettingValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $c = Get-Content $Path -Raw -Encoding UTF8
        if ($c -match "`"$Key`"\s*:\s*([^,}]+)") { return $matches[1].Trim().Trim('"') }
    } catch {}
    return $null
}

function Set-JsonBool {
    # Cambia una clave booleana en el JSON tanto si esta como true/false "pelado"
    # como si esta entre comillas "true"/"false". Devuelve si encontro la clave.
    param([string]$Content, [string]$Key, [bool]$Value)
    $valStr = if ($Value) { 'true' } else { 'false' }
    $patternQuoted   = "`"$Key`"\s*:\s*`"(?:true|false)`""
    $patternUnquoted = "`"$Key`"\s*:\s*(?:true|false)"
    if ($Content -match $patternQuoted) {
        return @{ Content = ($Content -replace $patternQuoted, "`"$Key`":`"$valStr`""); Found = $true }
    } elseif ($Content -match $patternUnquoted) {
        return @{ Content = ($Content -replace $patternUnquoted, "`"$Key`":$valStr"); Found = $true }
    }
    return @{ Content = $Content; Found = $false }
}

function Get-AllSettings {
    $paths = @()

    # -- BUSQUEDA EN LA RAIZ (por si es un equipo individual) --
    if (Test-Path "$TargetFolder\Settings.txt") {
        $paths += "$TargetFolder\Settings.txt"
    } else {
        $archivoPubli = Get-ChildItem -Path $TargetFolder -Filter "*publi*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($archivoPubli) {
            $paths += $archivoPubli.FullName
            Write-Log "  [DEBUG] Archivo Signage detectado en raiz: $($archivoPubli.Name)" "Green"
        }
    }

    # -- BUSQUEDA EN SUBCARPETAS (P1, P2, P3...) --
    $pFolders = Get-ChildItem -Path $TargetFolder -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^P\d+$' }
    foreach ($pf in $pFolders) {
        $pPath = "$($pf.FullName)\Settings.txt"
        if (Test-Path $pPath) {
            $paths += $pPath
        } else {
            $archivoPubliP = Get-ChildItem -Path $pf.FullName -Filter "*publi*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($archivoPubliP) {
                $paths += $archivoPubliP.FullName
                Write-Log "  [DEBUG] Archivo Signage detectado en $($pf.Name): $($archivoPubliP.Name)" "Green"
            }
        }
    }
    return $paths
}

$allPaths = Get-AllSettings
if ($allPaths.Count -eq 0) { Write-Log "No se encontraron archivos de configuración. Fin." "Yellow"; exit 0 }

function Get-NombreMaquina {
    param([string]$SettingsPath)
    $dir = (Get-Item $SettingsPath).DirectoryName
    $logFiles = Get-ChildItem -Path $dir -Filter "*.txt" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "Settings.txt|publi" } |
                Sort-Object LastWriteTime -Descending
    foreach ($lf in $logFiles) {
        $match = Select-String -Path $lf.FullName -Pattern 'Mensaje de saludo recibido:.*"NombreVisibleMaquina"\s*:\s*"([^"]+)"' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($match) { return $match.Matches[0].Groups[1].Value }
    }
    return ""
}

$IPLocal = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notmatch "^169" } | Select-Object -First 1).IPAddress

$apiAccesible = $false
try {
    $t = New-Object System.Net.Sockets.TcpClient
    $r = $t.BeginConnect($ServerIP, 8080, $null, $null)
    $apiAccesible = $r.AsyncWaitHandle.WaitOne(2000)
    if ($apiAccesible) { $t.EndConnect($r) }
    $t.Close()
} catch {}

if (-not $apiAccesible) { Write-Log "API no accesible. Fin." "Red"; exit 0 }

function Invoke-Api {
    param([string]$Method, [string]$Endpoint, [object]$Body = $null)
    try {
        $args = @{ Uri = "$ApiBase$Endpoint"; Method = $Method; TimeoutSec = 10; UseBasicParsing = $true }
        if ($Body) { $args.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $args.ContentType = "application/json; charset=utf-8" }
        $resp = Invoke-WebRequest @args
        return $resp.Content | ConvertFrom-Json
    } catch { return $null }
}

$reinicioProfundo = $false
$reinicioSuaveGlobal = $false
$reinicioHardware = $false
$apagadoTotal = $false
$uidsActivos = @()

foreach ($sp in $allPaths) {
    $Matricula = Get-MatriculaLocal -Path $sp
    $dirName = (Get-Item $sp).Directory.Name
    $puestoId = if ($dirName -match '^P\d+$') { $dirName } else { "MAIN" }
    $uid = "${IPLocal}_$puestoId"
    $uidsActivos += $uid 
    
    $qrStatus = Get-SettingValue -Path $sp -Key "mostrarQR_EnEspera"
    $pvStatus = Get-SettingValue -Path $sp -Key "mostrarCartelPVasco"
    $NombreMaquina = Get-NombreMaquina -SettingsPath $sp

    # -- DETECCION PARA EL PANEL (SIGNAGE / PLANETAS / CALENDARIO) --
    $MatriculaPanel = $Matricula
    $folderPath = (Get-Item $sp).DirectoryName
    $isSignage = (Get-ChildItem -Path $folderPath -Filter "*publi*" -File -ErrorAction SilentlyContinue)
    try {
        $cChk = Get-Content $sp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($isSignage) {
            $MatriculaPanel = "SIGNAGE"
        } elseif ($cChk -match '"tiempoTransicionPremios"') {
            $MatriculaPanel = "CALENDARIO"
        } elseif ([string]::IsNullOrWhiteSpace($Matricula)) {
            $MatriculaPanel = "PLANETAS"
        }
    } catch {}

    Write-Log "Puesto $puestoId -> $MatriculaPanel" "Cyan"

    Invoke-Api -Method "POST" -Endpoint "/api/kiosk/checkin" -Body @{ 
        uid = $uid; matricula = $MatriculaPanel; ip_actual = $IPLocal; hostname = $env:COMPUTERNAME; 
        puesto = $puestoId; ultima_conexion = (Get-Date).ToString("o"); nombre_maquina = $NombreMaquina;
        qr_status = ($qrStatus -eq "true"); pv_status = ($pvStatus -eq "true")
    } | Out-Null
    
    if ($SoloCheckin -or $Latido) { continue }
    
    Start-Sleep -Milliseconds 200 
    
    $data = Invoke-Api -Method "GET" -Endpoint "/api/kiosk/$uid/commands"
    if (-not $data -or -not $data.comandos_pendientes) { continue }
    
    $cmds = $data.comandos_pendientes
    $ejecutados = @{}
    $matarEstePuesto = $false
    
    # 1. MATRICULA (LOGICA ORIGINAL)
    if ($cmds.cambiar_matricula) {
        $nuevaMat = $cmds.cambiar_matricula
        Write-Log "  -> Cambiando matrícula a '$nuevaMat'" "Yellow"
        try {
            $c = Get-Content $sp -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($c)) {
                $c = $c -replace '"matricula"\s*:\s*"[^"]*"', ('"matricula":"' + $nuevaMat + '"')
                Set-Content -Path $sp -Value $c -Encoding UTF8 -ErrorAction Stop
            }
        } catch { Write-Log "  [!] Error en matricula: $($_.Exception.Message)" "Red" }
        $ejecutados.cambiar_matricula = ""
        $matarEstePuesto = $true
    }
    
    # 2. QR Y PV (LOGICA NUEVA INTEGRADA)
    if ($null -ne $cmds.toggle_qr -or $null -ne $cmds.toggle_pv -or $cmds.modificar_qr) {
        Write-Log "  -> Modificando QR/PV..." "Yellow"
        try {
            $c = Get-Content $sp -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($c)) {
                $cambioRealizado = $false

                if ($null -ne $cmds.toggle_qr) {
                    $r1 = Set-JsonBool -Content $c -Key "mostrarQR_EnEspera" -Value $cmds.toggle_qr
                    $c  = $r1.Content
                    $r2 = Set-JsonBool -Content $c -Key "mostrarQR_EnJuego" -Value $cmds.toggle_qr
                    $c  = $r2.Content
                    if ($r1.Found -or $r2.Found) { $cambioRealizado = $true }
                    else { Write-Log "  [!] No se encontraron mostrarQR_EnEspera/EnJuego en Settings" "Red" }
                    $ejecutados.toggle_qr = $null
                }
                if ($null -ne $cmds.toggle_pv) {
                    $r3 = Set-JsonBool -Content $c -Key "mostrarCartelPVasco" -Value $cmds.toggle_pv
                    $c  = $r3.Content
                    if ($r3.Found) { $cambioRealizado = $true }
                    else { Write-Log "  [!] No se encontro mostrarCartelPVasco en Settings" "Red" }
                    $ejecutados.toggle_pv = $null
                }
                if ($cmds.modificar_qr) {
                    $vals = $null
                    if ($cmds.modificar_qr -eq "ruleta") { $vals = @{ p=1.0; e=2.0; j=2.0 } }
                    elseif ($cmds.modificar_qr -eq "default") { $vals = @{ p=0.0; e=1.0; j=1.0 } }
                    elseif ($cmds.modificar_qr -match "posicion:([\d.]+),espera:([\d.]+),juego:([\d.]+)") { $vals = @{ p=[double]$matches[1]; e=[double]$matches[2]; j=[double]$matches[3] } }
                    if ($vals) {
                        $c = $c -replace '"posicionQR"\s*:\s*[\d.]+', ('"posicionQR":' + $vals.p)
                        $c = $c -replace '"escalaQR_EnEspera"\s*:\s*[\d.]+', ('"escalaQR_EnEspera":' + $vals.e)
                        $c = $c -replace '"escalaQR_EnJuego"\s*:\s*[\d.]+', ('"escalaQR_EnJuego":' + $vals.j)
                        $cambioRealizado = $true
                    }
                    $ejecutados.modificar_qr = ""
                }

                if ($cambioRealizado) {
                    Set-Content -Path $sp -Value $c -Encoding UTF8 -ErrorAction Stop
                    $matarEstePuesto = $true
                    Write-Log "  -> QR/PV actualizado correctamente." "Green"
                } else {
                    Write-Log "  [!] Ninguna clave coincidio, no se modifico el fichero." "Red"
                }
            }
        } catch { Write-Log "  [!] Error en QR/PV: $($_.Exception.Message)" "Red" }
    }

    # 3. OTROS COMANDOS (ORIGINALES)
    if ($cmds.corregir_imagen) { $matarEstePuesto = $true; $ejecutados.corregir_imagen = $false }
    if ($cmds.reemplazar_setting) {
        Write-Log "  -> Reemplazando Settings..." "Yellow"
        try {
            $SecurePass = ConvertTo-SecureString $ServerPass -AsPlainText -Force
            $Credential = New-Object System.Management.Automation.PSCredential($ServerUser, $SecurePass)
            $DriveName  = "CTRL$(Get-Random -Maximum 999)"
            New-PSDrive -Name $DriveName -PSProvider FileSystem -Root "\\$ServerIP\C$" -Credential $Credential -ErrorAction Stop | Out-Null
            if (Test-Path "${DriveName}:\ArchivosNuevos\Settings.txt") {
                if ($sp -match "publi") {
                    Write-Log "  [!] Omitiendo reemplazo de Settings en Signage" "Yellow"
                } else {
                    $newContent = Get-Content "${DriveName}:\ArchivosNuevos\Settings.txt" -Raw -Encoding UTF8 -ErrorAction Stop
                    if (-not [string]::IsNullOrWhiteSpace($newContent)) {
                        $matActual = Get-MatriculaLocal -Path $sp
                        $newContent = $newContent -replace '"matricula"\s*:\s*"[^"]*"', ('"matricula":"' + $matActual + '"')
                        Set-Content -Path $sp -Value $newContent -Encoding UTF8 -ErrorAction Stop
                    }
                }
                $reinicioSuaveGlobal = $true; $ejecutados.reemplazar_setting = $false
            }
            Remove-PSDrive -Name $DriveName -Force -ErrorAction SilentlyContinue
        } catch { Write-Log "  [!] Error Reemplazar Settings: $($_.Message)" "Red" }
    }
    if ($cmds.cambiar_ip_servidor) {
        Write-Log "  -> Cambiando IP servidor a $($cmds.cambiar_ip_servidor)..." "Yellow"
        try {
            $c = Get-Content $sp -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($c)) {
                # Usamos la logica de reemplazo mas robusta que habia antes
                $c = $c -replace '"socketURL"\s*:\s*"http://[^:]+:', ('"socketURL":"http://' + $cmds.cambiar_ip_servidor + ':')
                Set-Content -Path $sp -Value $c -Encoding UTF8 -ErrorAction Stop
                Write-Log "  -> IP servidor actualizada correctamente en Settings." "Green"
            }
        } catch { 
            Write-Log "  [!] Error editando IP en ${sp}: $($_.Exception.Message)" "Red" 
        }
        $reinicioSuaveGlobal = $true; $ejecutados.cambiar_ip_servidor = ""
    }
    if ($cmds.actualizar_unity) { if (Test-Path "$KioskRoot\version.txt") { Remove-Item "$KioskRoot\version.txt" -Force }; $reinicioProfundo = $true; $ejecutados.actualizar_unity = $false }
    if ($cmds.reiniciar_app) { $reinicioProfundo = $true; $ejecutados.reiniciar_app = $false }
    if ($cmds.reiniciar_pc) { $reinicioHardware = $true; $ejecutados.reiniciar_pc = $false }
    if ($cmds.apagar_pc) { $apagadoTotal = $true; $ejecutados.apagar_pc = $false }
    
    if ($ejecutados.Count -gt 0) { Invoke-Api -Method "POST" -Endpoint "/api/kiosk/$uid/clear" -Body $ejecutados | Out-Null }

    # v2: check-in final de este puesto: el servidor (y el panel) ven al
    # momento la matricula/QR/PV nuevos en vez de los datos de antes del comando
    if ($ejecutados.Count -gt 0) {
        $MatriculaF = Get-MatriculaLocal -Path $sp
        $MatriculaPanelF = $MatriculaF
        try {
            $cF = Get-Content $sp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($isSignage) { $MatriculaPanelF = "SIGNAGE" }
            elseif ($cF -match '"tiempoTransicionPremios"') { $MatriculaPanelF = "CALENDARIO" }
            elseif ([string]::IsNullOrWhiteSpace($MatriculaF)) { $MatriculaPanelF = "PLANETAS" }
        } catch {}
        Invoke-Api -Method "POST" -Endpoint "/api/kiosk/checkin" -Body @{
            uid = $uid; matricula = $MatriculaPanelF; ip_actual = $IPLocal; hostname = $env:COMPUTERNAME;
            puesto = $puestoId; ultima_conexion = (Get-Date).ToString("o"); nombre_maquina = (Get-NombreMaquina -SettingsPath $sp);
            qr_status = ((Get-SettingValue -Path $sp -Key "mostrarQR_EnEspera") -eq "true"); pv_status = ((Get-SettingValue -Path $sp -Key "mostrarCartelPVasco") -eq "true")
        } | Out-Null
    }

    if ($matarEstePuesto -and -not $reinicioProfundo -and -not $reinicioSuaveGlobal -and -not $reinicioHardware) {
        Write-Log "  [FRANCOTIRADOR] Matando exclusivamente el Unity de este puesto..." "Cyan"
        $folderPath = (Get-Item $sp).DirectoryName
        $procs = Get-WmiObject Win32_Process -Filter "Name='CalimaJackpot.exe'" | Where-Object { $_.ExecutablePath -ne $null -and $_.ExecutablePath.StartsWith($folderPath) }
        if ($procs) {
            foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        } else {
            Get-Process -Name "CalimaJackpot" -ErrorAction SilentlyContinue | Where-Object { $_.Path -ne $null -and $_.Path.StartsWith($folderPath) } | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($uidsActivos.Count -gt 0) { Invoke-Api -Method "POST" -Endpoint "/api/kiosk/sync" -Body @{ ip = $IPLocal; activos = $uidsActivos } | Out-Null }

if ($SoloCheckin) {
    Write-Log "=== CONTROL_KIOSK (solo-checkin) FINALIZADO ===" "Cyan"
    exit 0
}

if ($Latido) {
    Write-Log "=== CONTROL_KIOSK (latido) FINALIZADO ===" "Cyan"
    exit 0
}

if ($apagadoTotal) { Write-Log "Apagando el equipo (comando apagar_pc)..." "Red"; shutdown.exe /s /t 0 /f; exit 0 }
if ($reinicioHardware) { shutdown.exe /r /t 0 /f; exit 0 }
elseif ($reinicioProfundo) {
    Write-Log "Ejecutando reinicio de software profundo via Tarea Programada..." "Magenta"
    Get-Process | Where-Object { $_.Name -like "CalimaJackpot*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    $vigilantes = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' AND CommandLine LIKE '%vigilante.ps1%'"
    if ($vigilantes) { foreach ($v in $vigilantes) { Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue } }
    Get-Process | Where-Object { $_.Name -eq "cmd" } | Stop-Process -Force -ErrorAction SilentlyContinue

    $taskName  = "RelanzarKiosk_$(Get-Random)"
    $startTime = (Get-Date).AddSeconds(5).ToString("HH:mm")
    $startDate = (Get-Date).ToString("MM/dd/yyyy")
    schtasks /create /tn $taskName /tr "cmd.exe /c C:\Kiosk\inicio.bat" /sc ONCE /st $startTime /sd $startDate /f /it /rl HIGHEST | Out-Null
    schtasks /run /tn $taskName | Out-Null
    Start-Sleep -Seconds 3
    schtasks /delete /tn $taskName /f | Out-Null
} 
elseif ($reinicioSuaveGlobal) { Get-Process | Where-Object { $_.Name -like "CalimaJackpot*" } | Stop-Process -Force -ErrorAction SilentlyContinue }

Write-Log "=== CONTROL_KIOSK FINALIZADO ===" "Cyan"
exit 0
