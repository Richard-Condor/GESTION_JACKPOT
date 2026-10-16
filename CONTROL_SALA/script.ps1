# ============================================================================
# script.ps1 - CAMPANA DE ACTUALIZACION DE SALA (panel de gestion v2)
# v4.3 (2026-10-16): SIN cambios de logica. Solo cambia la huella para que
# las salas lo descarguen de nuevo y lo ejecuten de verdad con el
# actualizador v5.1 (el v5 ejecutaba el script sin extension .ps1).
#
# Pensado para el auto-updater de GitHub: se sube a CONTROL_SALA junto a
# panel.html, operador.html, api_server.nuevo, control_kiosk.ps1 y
# vigilante.ps1. El updater copia todo a C:\Control y ejecuta este script
# en un proceso aparte. Tambien se puede lanzar a mano en el servidor
# para probarlo en una sala (hace exactamente lo mismo).
#
# FASE A - Migracion de la API del servidor: rescata el nombre de la sala
#   y la IP del api_server.ps1 actual, los inyecta en api_server.nuevo,
#   respalda el viejo (.bak-<fecha>) y pone el nuevo. Del reinicio del
#   proceso se encarga el updater/watchdog (a mano: reiniciar la API).
# FASE B - Equipos de la sala (segun los JSON de C:\Control\kiosks):
#   por cada equipo, con los metodos probados el 2026-10-15/16:
#   - Entrega control_kiosk.ps1 y vigilante.ps1 por net use + UNC,
#     verificando el SHA256 del fichero aterrizado.
#   - Lee EnableLUA por WMI (StdRegProv) y lo pone a 0 si hace falta:
#     el equipo se auto-prepara en el siguiente arranque para siempre.
#   - Si algo cambio, reinicia el equipo por WMI (el vigilante es
#     residente: el nuevo solo manda tras el reinicio).
# FASE C - Informe: CSV con el detalle por equipo en C:\Control y una
#   fila-resumen a la hoja de Google de siempre (la del RustDesk):
#   nombre=sala, id=n. de equipos, pc=hechos bien, usuario=fallos.
#
# Todo queda en C:\Control\campana.log. Si una fase falla, las demas
# siguen; cada equipo es independiente de los otros.
#
# Correccion 2026-10-16 (v4, tras la prueba en HUMANES):
#  - SIN REINICIO AUTOMATICO (decision de Richard, 2026-10-16): la
#    campana actualiza ficheros y LUA y reporta, pero NUNCA reinicia
#    un equipo. El reinicio lo ordena el despues, cuando quiera,
#    desde el sistema de gestion. Asi un despliegue por GitHub no
#    puede reiniciar todas las salas a la vez. Los equipos con
#    cambios salen COMPLETO con el motivo «Actualizado; reinicio
#    pendiente (lo ordena gestion)».
#  - Duplicados: el JSON repetido por matricula O por nombre, cuyo
#    gemelo si responde y cuya IP no responde a nada, se mueve a
#    C:\Control\kiosks_duplicados\<fecha> en vez de seguir ensuciando
#    el censo: sale en el informe como DUPLICADO, fuera de los totales
#    y de la hoja.
#  - Retirados: el JSON solitario (sin gemelo) de un equipo que en la
#    pasada sale SIN ACCESO o SIN RESPUESTA y lleva mas de 14 dias
#    sin reportar tambien se aparta, como RETIRADO y fuera de totales.
# ============================================================================

$ControlPath = "C:\Control"
$KiosksDir   = Join-Path $ControlPath "kiosks"
$LogFile     = Join-Path $ControlPath "campana.log"
$ClaveReg    = "SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$HKLM        = 2147483650

# Credenciales de los kiosks (las mismas del Despliegue)
$User1        = "kiosk"               # Credencial Principal
$Pass1        = "Strato.2019!"
$User2        = "ApagaRemoto"         # Credencial de Respaldo
$Pass2        = "Apaga123!"
$Cred1 = New-Object System.Management.Automation.PSCredential($User1, (ConvertTo-SecureString $Pass1 -AsPlainText -Force))
$Cred2 = New-Object System.Management.Automation.PSCredential($User2, (ConvertTo-SecureString $Pass2 -AsPlainText -Force))

# Hoja de Google (la misma del instalador RustDesk) para el resumen
$SheetsUrl = "https://script.google.com/macros/s/AKfycbxb415JbG0_-y2hmMtrhGN6nUtAqGGOqV5T33KnNfrbIoi_-e4kq2INHk-PeCDMPD44gw/exec"

function Log-Campana([string]$m) {
    $linea = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m"
    Add-Content -Path $LogFile -Value $linea -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $linea
}

function Test-Puerto([string]$IP, [int]$Puerto, [int]$Ms = 700) {
    $t = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $t.BeginConnect($IP, $Puerto, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($Ms)) { $t.EndConnect($ar); return $t.Connected }
        return $false
    } catch { return $false } finally { $t.Close() }
}

function Get-RegDWORD([string]$IP, $Cred, [string]$Nombre) {
    try {
        $r = Invoke-WmiMethod -ComputerName $IP -Credential $Cred -Namespace "root\default" -Class StdRegProv -Name GetDWORDValue -ArgumentList $HKLM, $ClaveReg, $Nombre -ErrorAction Stop
        return @{ Rv = [int]$r.ReturnValue; Valor = $r.uValue }
    } catch { return $null }
}

function Set-RegDWORD([string]$IP, $Cred, [string]$Nombre, [int]$Valor) {
    try {
        $r = Invoke-WmiMethod -ComputerName $IP -Credential $Cred -Namespace "root\default" -Class StdRegProv -Name SetDWORDValue -ArgumentList $HKLM, $ClaveReg, $Nombre, $Valor -ErrorAction Stop
        return ([int]$r.ReturnValue -eq 0)
    } catch { return $false }
}

$script:VivoCache = @{}
function Test-EquipoVivo([string]$IP) {
    if ($script:VivoCache.ContainsKey($IP)) { return $script:VivoCache[$IP] }
    $vivo = $false
    try { if (Test-Connection $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) { $vivo = $true } } catch {}
    if (-not $vivo) { $vivo = [bool](Test-Puerto $IP 445) }
    if (-not $vivo) { $vivo = [bool](Test-Puerto $IP 135) }
    $script:VivoCache[$IP] = $vivo
    return $vivo
}

function Get-Retirados($Filas, $Entradas, $GruposMatricula, $GruposNombre, $YaApartados, [int]$Dias) {
    # Un equipo es "retirado" si su fila salio SIN ACCESO o SIN
    # RESPUESTA y TODOS sus JSON cumplen a la vez: sin gemelo (ni por
    # matricula ni por nombre) y sin reportar desde hace mas de $Dias
    # dias. Apartar es reversible: si el equipo volviera a encenderse,
    # su propio check-in recrea el JSON.
    $limite = (Get-Date).AddDays(-$Dias)
    $salida = @()
    foreach ($f in $Filas) {
        if ($f.Estado -ne "SIN ACCESO" -and $f.Estado -ne "SIN RESPUESTA") { continue }
        $jsons = @($Entradas | Where-Object { $_.IP -eq $f.IP -and $YaApartados -notcontains $_.Archivo })
        if ($jsons.Count -lt 1) { continue }
        $esRetirado = $true
        foreach ($e in $jsons) {
            if ($e.Ultima -ge $limite) { $esRetirado = $false }
            if ($e.Matricula -and $GruposMatricula.ContainsKey($e.Matricula) -and @($GruposMatricula[$e.Matricula]).Count -gt 1) { $esRetirado = $false }
            if ($e.Nombre -and $GruposNombre.ContainsKey($e.Nombre) -and @($GruposNombre[$e.Nombre]).Count -gt 1) { $esRetirado = $false }
        }
        if ($esRetirado) { $salida += @{ Fila = $f; Jsons = $jsons } }
    }
    return $salida
}

Log-Campana "================ CAMPANA DE ACTUALIZACION ================"

# ============================================================================
# FASE A - Migracion de la API (identica logica a la probada en Villalba)
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
# FASE B - Equipos de la sala
# ============================================================================
$FicherosKiosk = @("control_kiosk.ps1", "vigilante.ps1")
$HashesOrigen  = @{}
foreach ($f in $FicherosKiosk) {
    $p = Join-Path $ControlPath $f
    if (Test-Path $p) { $HashesOrigen[$f] = (Get-FileHash $p -Algorithm SHA256).Hash }
}
$MisIPs = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress)

$EntradasJSON = @()
if (Test-Path $KiosksDir) {
    foreach ($jf in (Get-ChildItem $KiosksDir -Filter *.json -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $ip = [string]$j.ip_actual
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
                $ult = [datetime]::MinValue
                try { if ($j.ultima_conexion) { $ult = [datetime]::Parse([string]$j.ultima_conexion) } } catch {}
                $EntradasJSON += [PSCustomObject]@{ Archivo = $jf.FullName; Uid = [string]$j.uid; IP = $ip; Nombre = [string]$j.nombre_maquina; Matricula = [string]$j.matricula; Ultima = $ult }
            }
        } catch {}
    }
}

# --- Pasada de duplicados: fantasmas a cuarentena (ver cabecera) ---
$FilasDuplicados = @()
$fantasmaArchivos = @()
$gruposMatricula = @{}
$gruposNombre = @{}
foreach ($e in $EntradasJSON) {
    if ($e.Matricula -and $e.Matricula -notmatch "PLANETAS|SIGNAGE|CALENDARIO") {
        if (-not $gruposMatricula.ContainsKey($e.Matricula)) { $gruposMatricula[$e.Matricula] = @() }
        $gruposMatricula[$e.Matricula] += $e
    }
    if ($e.Nombre -and $e.Nombre -notmatch "PLANETAS|SIGNAGE|CALENDARIO") {
        if (-not $gruposNombre.ContainsKey($e.Nombre)) { $gruposNombre[$e.Nombre] = @() }
        $gruposNombre[$e.Nombre] += $e
    }
}
$candidatos = @()
foreach ($grupos in @($gruposMatricula, $gruposNombre)) {
    foreach ($clave in $grupos.Keys) {
        $grupo = @($grupos[$clave])
        if ($grupo.Count -lt 2) { continue }
        $vivos = @($grupo | Where-Object { Test-EquipoVivo $_.IP })
        if ($vivos.Count -lt 1) { continue }
        $bueno = $vivos | Sort-Object Ultima -Descending | Select-Object -First 1
        $ipsQueResponden = @()
        foreach ($v in $vivos) { if ($ipsQueResponden -notcontains $v.IP) { $ipsQueResponden += $v.IP } }
        if ($ipsQueResponden.Count -gt 1) { Log-Campana "  REVISAR: '$clave' aparece en varias IPs que responden ($($ipsQueResponden -join ', ')); no se aparta ninguna." }
        foreach ($e in $grupo) {
            if ($e.Archivo -eq $bueno.Archivo) { continue }
            if ($candidatos -contains $e) { continue }
            if ($e.IP -eq $bueno.IP) { if ($e.Ultima -lt $bueno.Ultima) { $candidatos += $e }; continue }
            if (Test-EquipoVivo $e.IP) { continue }
            $candidatos += $e
        }
    }
}
if ($candidatos.Count -gt 0) {
    $carpetaDup = Join-Path $ControlPath ("kiosks_duplicados\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $carpetaDup -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($e in $candidatos) {
        try {
            Move-Item $e.Archivo (Join-Path $carpetaDup (Split-Path $e.Archivo -Leaf)) -Force -ErrorAction Stop
            $fantasmaArchivos += $e.Archivo
            Log-Campana "  DUPLICADO: $($e.Nombre) ($($e.IP)) - matricula $($e.Matricula) repetida en un JSON que si responde; fichero movido a cuarentena."
            $fd = [ordered]@{ Equipo = $e.Nombre; IP = $e.IP; Ficheros = ""; LUA_antes = ""; LUA_despues = ""; Reinicio = "No"; Estado = "DUPLICADO"; Motivo = "Matricula $($e.Matricula) repetida en otro JSON que si responde; fichero movido a $carpetaDup" }
            $FilasDuplicados += New-Object PSObject -Property $fd
        } catch { Log-Campana "  DUPLICADO: no se pudo mover el JSON de $($e.Nombre) ($($e.IP)): $($_.Exception.Message)" }
    }
    if ($FilasDuplicados.Count -gt 0) { Log-Campana "FASE B: $($FilasDuplicados.Count) JSON duplicado(s) apartado(s) a cuarentena." }
}

$Equipos = @{}
foreach ($e in $EntradasJSON) {
    if ($fantasmaArchivos -contains $e.Archivo) { continue }
    if (-not $Equipos.ContainsKey($e.IP)) { $Equipos[$e.IP] = @() }
    $Equipos[$e.IP] += $e.Nombre
}
Log-Campana "FASE B: $($Equipos.Count) equipo(s) en los JSON de la sala."

$Filas = @()
foreach ($ip in ($Equipos.Keys | Sort-Object)) {
    if ($MisIPs -contains $ip) { Log-Campana "  $ip es el propio servidor; se salta."; continue }
    $nombres = ($Equipos[$ip] | Select-Object -Unique) -join ", "
    $fila = [ordered]@{ Equipo = $nombres; IP = $ip; Ficheros = ""; LUA_antes = ""; LUA_despues = ""; Reinicio = "No"; Estado = ""; Motivo = "" }
    Log-Campana "  --- $nombres ($ip) ---"
    $ping = Test-Connection $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
    $hay445 = Test-Puerto $ip 445
    $hay135 = Test-Puerto $ip 135
    if (-not $ping -and -not $hay445 -and -not $hay135) {
        $fila.Estado = "SIN RESPUESTA"; $fila.Motivo = "Sin ping ni puertos 445/135"
        Log-Campana "    Sin respuesta de red."
        $Filas += New-Object PSObject -Property $fila; continue
    }

    $cambios = $false

    # --- Entrega de ficheros por net use + UNC ---
    $fichOK = $false; $yaEstaban = $false
    if ($HashesOrigen.Count -gt 0) {
        $conectado = $false
        net use "\\$ip\C$" /delete /y 2>&1 | Out-Null
        net use "\\$ip\C$" /user:$User1 $Pass1 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $conectado = $true }
        else {
            net use "\\$ip\C$" /user:$User2 $Pass2 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $conectado = $true }
        }
        if ($conectado) {
            $resultados = @()
            foreach ($f in $FicherosKiosk) {
                $origen = Join-Path $ControlPath $f
                $destino = "\\$ip\C$\Kiosk\$f"
                try {
                    if ((Test-Path $destino) -and ((Get-FileHash $destino -Algorithm SHA256).Hash -eq $HashesOrigen[$f])) {
                        $resultados += "$f ya estaba"; $yaEstaban = $true
                    } else {
                        Copy-Item $origen $destino -Force -ErrorAction Stop
                        if ((Get-FileHash $destino -Algorithm SHA256).Hash -eq $HashesOrigen[$f]) { $resultados += "$f OK"; $cambios = $true }
                        else { $resultados += "$f SIN VERIFICAR" }
                    }
                } catch { $resultados += "$f ERROR" }
            }
            $fila.Ficheros = $resultados -join "; "
            $fichOK = ($resultados -notmatch 'ERROR|SIN VERIFICAR')
            net use "\\$ip\C$" /delete /y 2>&1 | Out-Null
        } else { $fila.Ficheros = "sin acceso SMB" }
    } else { $fila.Ficheros = "sin ficheros en Control" }

    # --- EnableLUA por WMI ---
    $credWmi = $null
    $lectura = Get-RegDWORD $ip $Cred1 "EnableLUA"
    if ($lectura) { $credWmi = $Cred1 } else { $lectura = Get-RegDWORD $ip $Cred2 "EnableLUA"; if ($lectura) { $credWmi = $Cred2 } }
    if ($lectura) {
        if ($lectura.Rv -eq 0) { $fila.LUA_antes = [string]$lectura.Valor } else { $fila.LUA_antes = "1 (sin valor)" }
        $luaAntes = 1; if ($lectura.Rv -eq 0 -and $null -ne $lectura.Valor) { $luaAntes = [int]$lectura.Valor }
        if ($luaAntes -eq 0) { $fila.LUA_despues = "0" }
        elseif (Set-RegDWORD $ip $credWmi "EnableLUA" 0) {
            $fila.LUA_despues = "0"; $cambios = $true
            Log-Campana "    EnableLUA puesto a 0."
        } else { $fila.LUA_despues = "ERROR" }
    } else { $fila.LUA_antes = "sin WMI" }

    # --- Sin reinicio automatico: los cambios quedan en disco y el
    # reinicio lo ordena Richard desde gestion cuando quiera. ---

    # --- Estado final ---
    $luaBien = ($fila.LUA_despues -eq "0") -or ($fila.LUA_antes -eq "0")
    if ($fichOK -and $luaBien) { $fila.Estado = "COMPLETO" }
    elseif ($fichOK -or $luaBien) { $fila.Estado = "PARCIAL" }
    else { $fila.Estado = "SIN ACCESO" }
    if ($fila.Estado -eq "COMPLETO" -and $cambios) { $fila.Motivo = "Actualizado; reinicio pendiente (lo ordena gestion)" }
    if ($fila.Estado -ne "COMPLETO" -and -not $fila.Motivo) {
        $fila.Motivo = "Ficheros: $($fila.Ficheros) / LUA: $($fila.LUA_antes)->$($fila.LUA_despues)"
    }
    Log-Campana "    Resultado: $($fila.Estado)"
    $Filas += New-Object PSObject -Property $fila
}

# ============================================================================
# FASE C - Informe
# ============================================================================
# --- Pasada de retirados: solitarios sin acceso y sin reporte reciente ---
$DiasRetirado = 14
$retirados = Get-Retirados $Filas $EntradasJSON $gruposMatricula $gruposNombre $fantasmaArchivos $DiasRetirado
if ($retirados.Count -gt 0) {
    $carpetaRet = Join-Path $ControlPath ("kiosks_duplicados\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Path $carpetaRet -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($r in $retirados) {
        $movidos = 0
        foreach ($e in $r.Jsons) { try { Move-Item $e.Archivo (Join-Path $carpetaRet (Split-Path $e.Archivo -Leaf)) -Force -ErrorAction Stop; $movidos++ } catch {} }
        if ($movidos -gt 0) {
            $r.Fila.Estado = "RETIRADO"
            $r.Fila.Motivo = "Sin acceso en la pasada y sin reporte en mas de $DiasRetirado dias; JSON apartado a $carpetaRet"
            Log-Campana "  RETIRADO: $($r.Fila.Equipo) ($($r.Fila.IP)) - $movidos JSON apartado(s)."
        }
    }
}

$Filas += $FilasDuplicados
$total     = @($Filas | Where-Object { $_.Estado -ne "DUPLICADO" -and $_.Estado -ne "RETIRADO" }).Count
$completos = @($Filas | Where-Object { $_.Estado -eq "COMPLETO" }).Count
$fallos    = $total - $completos
try {
    $csv = Join-Path $ControlPath ("informe_campana_" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".csv")
    $Filas | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    Log-Campana "FASE C: informe detallado en $csv"
} catch { Log-Campana "FASE C: no se pudo guardar el CSV: $($_.Exception.Message)" }

if ($SheetsUrl -ne "") {
    $payload = "{""nombre"":""$($script:NombreSala -replace '"','')"",""id"":""$total"",""pc"":""$completos"",""usuario"":""$fallos"",""fecha"":""$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')""}"
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
    if ($enviado) { Log-Campana "FASE C: resumen enviado a la hoja (sala '$($script:NombreSala)': $completos/$total bien, $fallos con fallo)." }
    else { Log-Campana "FASE C: no se pudo enviar el resumen a la hoja; queda el CSV local." }
}
Log-Campana "================ FIN: $completos de $total equipos completos ================"

# ============================================================================
# CIERRE v4.3 - Si la FASE A ha migrado la API, reiniciarla para aplicar
# ============================================================================
# El api_server.ps1 nuevo no se aplica hasta que el proceso muere y el
# lanzador lo levanta: sin muerte no hay actualizacion. Se programa un
# matar diferido (15 s) para que, cuando es el propio actualizador quien
# ha lanzado este script, le de tiempo a apuntar la ejecucion en su
# manifiesto antes de morir.
if ($script:ApiMigrada) {
    try {
        $apiProcs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "api_server\.ps1" -and $_.ProcessId -ne $PID }
        foreach ($p in $apiProcs) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Sleep -Seconds 15; Stop-Process -Id $($p.ProcessId) -Force`"" -WindowStyle Hidden
            Log-Campana "CIERRE: reinicio de la API programado en 15 s (PID $($p.ProcessId)) para aplicar la migracion."
        }
    } catch { Log-Campana "CIERRE: no se pudo programar el reinicio de la API: $($_.Exception.Message)" }
}
