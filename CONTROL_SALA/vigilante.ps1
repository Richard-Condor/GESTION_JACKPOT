# ===============================================================================
#                    VIGILANTE INTELIGENTE (PowerShell) v3.0
#   Base: v2.6 (salud "No Responde", resolucion, RustDesk, WinRM, red).
#   Novedades: Signage dinamico (carpeta con "*publi*") siempre detras de los demas Unity,
#   monopuesto Signage = principal, ocultar barra de tareas solo si existe,
#   vigilancia opcional de CalimaJackpot_GTTS y Ondeon SMART (solo si existen).
# ===============================================================================

Write-Host "Iniciando vigilante inteligente v3.0..."
$Root = "C:\Kiosk\01.CalimaJackpot"
$ScriptPosicionamiento = "C:\Kiosk\posicionamiento.ps1"
$modo = 1
$procesosAsegurar = @()

# --- Detección de Modo ---
if (Test-Path "$Root\P4") {
    if (Test-Path "$Root\P4\CalimaJackpot_Banner.exe") { $modo = 3 } else { $modo = 4 }
} elseif ((Test-Path "$Root\P1") -and (Test-Path "$Root\P2")) {
    $modo = 2
}
Write-Host "MODO DETECTADO: $modo"

# --- Definir la lista de procesos Unity que deben estar vivos según el modo (PuestoId sirve para detectar Signage) ---
if ($modo -eq 1) {
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\CalimaJackpot.exe"; PuestoId = "P0" }
} elseif ($modo -eq 2) {
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P1\CalimaJackpot.exe"; PuestoId = "P1" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P2\CalimaJackpot.exe"; PuestoId = "P2" }
} elseif ($modo -eq 3) {
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P1\CalimaJackpot.exe"; PuestoId = "P1" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P2\CalimaJackpot.exe"; PuestoId = "P2" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P3\CalimaJackpot.exe"; PuestoId = "P3" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot_Banner"; Path = "$Root\P4\CalimaJackpot_Banner.exe"; PuestoId = "P4" }
} elseif ($modo -eq 4) {
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P1\CalimaJackpot.exe"; PuestoId = "P1" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P2\CalimaJackpot.exe"; PuestoId = "P2" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P3\CalimaJackpot.exe"; PuestoId = "P3" }
    $procesosAsegurar += [pscustomobject]@{ Name = "CalimaJackpot"; Path = "$Root\P4\CalimaJackpot.exe"; PuestoId = "P4" }
}
Write-Host "Se asegurará la ejecución de $($procesosAsegurar.Count) procesos Unity."

# --- Apps OPCIONALES: solo se vigilan si existe su ejecutable (se comprueba en cada vuelta) ---
$CooldownRelanzarSeg = 60
$appsOpcionales = @(
    [pscustomobject]@{ Nombre = "CalimaJackpot_GTTS"; Proceso = "CalimaJackpot_GTTS"; Path = "C:\01.TTS\CalimaJackpot_GTTS.exe"; AlFondo = $false; UltimoLanzamiento = [datetime]::MinValue },
    [pscustomobject]@{ Nombre = "Ondeon SMART"; Proceso = "ondeon-smart"; Path = "C:\Users\kiosk\AppData\Local\Ondeon SMART\ondeon-smart.exe"; AlFondo = $true; UltimoLanzamiento = [datetime]::MinValue }
)

# --- Detección de SIGNAGE (misma lógica que control_kiosk.ps1: carpeta del puesto con un fichero "*publi*") ---
function Get-CarpetaPuesto {
    param([string]$PuestoId)
    if ($PuestoId -eq "P0") { return $Root } else { return "$Root\$PuestoId" }
}
function Test-EsSignage {
    param([string]$PuestoId)
    $carpeta = Get-CarpetaPuesto -PuestoId $PuestoId
    if (-not (Test-Path $carpeta)) { return $false }
    $archivoPubli = Get-ChildItem -Path $carpeta -Filter "*publi*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$archivoPubli
}

# --- INICIALIZACIÓN DE VIGILANCIA DE RESOLUCIÓN ---
Add-Type -AssemblyName System.Windows.Forms
$anchoActual = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
$altoActual = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
Write-Host "Vigilancia de resolución iniciada para ${anchoActual}x${altoActual}."

# --- API DE WINDOWS: Z-ORDER Y BARRA DE TAREAS ---
if (-not ([System.Management.Automation.PSTypeName]'WinHelpers').Type) { Add-Type @'
    using System; using System.Runtime.InteropServices;
    public class WinHelpers {
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr hAfter, int X, int Y, int W, int H, uint f);
        [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string win);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    }
'@ }
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$HWND_BOTTOM = [IntPtr](1)
$SWP_NOMOVE = 0x0002; $SWP_NOSIZE = 0x0001; $SWP_NOACTIVATE = 0x0010


# --- Comprueba si hay alguna ventana "real" (con o sin titulo) POR ENCIMA de $h que no sea una de las permitidas ---
# Se ignoran: ventanas invisibles, tool windows, ventanas "cloaked" (fantasmas de UWP) y ventanas minusculas.
function Test-AlguienPorEncima {
    param($h, $permitidos)
    $w = [WinHelpers]::GetWindow($h, 3)   # 3 = GW_HWNDPREV (ventana inmediatamente por encima)
    while ($w -ne [IntPtr]::Zero) {
        if (($permitidos -notcontains $w) -and [WinHelpers]::IsWindowVisible($w)) {
            $ex = [WinHelpers]::GetWindowLong($w, -20)                                   # GWL_EXSTYLE
            $cloaked = 0
            [void][WinHelpers]::DwmGetWindowAttribute($w, 14, [ref]$cloaked, 4)          # 14 = DWMWA_CLOAKED
            $r = New-Object WinHelpers+RECT
            [void][WinHelpers]::GetWindowRect($w, [ref]$r)
            $grande = (($r.R - $r.L) -gt 50) -and (($r.B - $r.T) -gt 50)
            if ((($ex -band 0x80) -eq 0) -and ($cloaked -eq 0) -and $grande) { return $true }   # 0x80 = WS_EX_TOOLWINDOW
        }
        $w = [WinHelpers]::GetWindow($w, 3)
    }
    return $false
}

# --- Bucle infinito de vigilancia ---
$ScriptControl = "C:\Kiosk\control_kiosk.ps1"
$contadorLatido = 0
while ($true) {

    # --- CHEQUEO DE PERFIL DE RED (reaplica reglas si WiFi reconectó como Pública) ---
    $perfilesPublicos = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq "Public" }
    if ($perfilesPublicos) {
        Write-Host "$(Get-Date): Red detectada como Pública. Reaplicando reglas de firewall y forzando Privada..." -ForegroundColor Yellow
        Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
        reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
        netsh advfirewall firewall set rule group="Administración remota de servicios" new enable=yes | Out-Null
        netsh advfirewall firewall set rule group="Instrumental de administración de Windows (WMI)" new enable=yes | Out-Null
        netsh advfirewall firewall add rule name="RPC-EP" dir=in action=allow protocol=TCP localport=135 | Out-Null
        netsh advfirewall firewall set rule group="Administración remota de Windows" new enable=yes | Out-Null
        netsh advfirewall firewall add rule name="Permitir Ping" protocol=icmpv4:8,any dir=in action=allow | Out-Null
        Write-Host "$(Get-Date): Reglas reaplicadas correctamente." -ForegroundColor Green
    }

    # --- VIGILANCIA DEL SERVICIO RUSTDESK ---
    $rdService = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if ($rdService -and $rdService.Status -ne 'Running') {
        Write-Host "$(Get-Date): ALERTA: Servicio RustDesk detenido. Arrancando..." -ForegroundColor Yellow
        Start-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    }

    # --- VIGILANCIA DEL SERVICIO WINRM (necesario para push entre VLANs) ---
    $winrmService = Get-Service -Name "WinRM" -ErrorAction SilentlyContinue
    if ($winrmService -and $winrmService.Status -ne 'Running') {
        Write-Host "$(Get-Date): ALERTA: Servicio WinRM detenido. Reactivando..." -ForegroundColor Yellow
        Start-Service -Name "WinRM" -ErrorAction SilentlyContinue
        winrm quickconfig -quiet 2>$null
    }

    # --- CHEQUEO DE RESOLUCIÓN DE PANTALLA ---
    $anchoNuevo = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
    $altoNuevo = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height

    if ($anchoNuevo -ne $anchoActual -or $altoNuevo -ne $altoActual) {
        Write-Host "$(Get-Date): ¡CAMBIO DE RESOLUCIÓN DETECTADO! De ${anchoActual}x${altoActual} a ${anchoNuevo}x${altoNuevo}." -ForegroundColor Yellow
        Write-Host "$(Get-Date): Reposicionando TODAS las ventanas..." -ForegroundColor Yellow

        # Llamamos al script de posicionamiento SIN -Solo* para que ajuste todo
        powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPosicionamiento -NoLanzar

        # Actualizamos la resolución de referencia para no volver a entrar aquí
        $anchoActual = $anchoNuevo
        $altoActual = $altoNuevo
        Write-Host "$(Get-Date): Reposicionamiento completado." -ForegroundColor Green
    }

    # --- CHEQUEO DE PROCESOS UNITY ---
    $procesosActivos = Get-Process -Name "CalimaJackpot*" -ErrorAction SilentlyContinue
    foreach ($proceso in $procesosAsegurar) {
        $procesoActivoEncontrado = $null
        if ($procesosActivos) {
            foreach ($activo in $procesosActivos) { try { if ($activo.Path -eq $proceso.Path) { $procesoActivoEncontrado = $activo; break } } catch { } }
        }

        if (-not $procesoActivoEncontrado) {
            # --- Lógica de RELANZAMIENTO (si el proceso no existe) ---
            Write-Host "$(Get-Date): Falta el proceso $($proceso.Path). Relanzando..."
            if (Test-Path $proceso.Path) {
                $workingDir = Split-Path $proceso.Path -Parent; Start-Process -FilePath $proceso.Path -WorkingDirectory $workingDir
                Write-Host "Dando 15s para que Unity cargue y reposicionando..."; Start-Sleep -Seconds 15; powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPosicionamiento -SoloUnity -NoLanzar
            } else { Write-Host "ERROR: No se encuentra el ejecutable $($proceso.Path)" }
        } else {
            # --- LÓGICA DE CHEQUEO DE SALUD (si el proceso SÍ existe) ---
            if (-not $procesoActivoEncontrado.Responding) {
                Write-Host "$(Get-Date): ¡ALERTA! El proceso $($proceso.Path) (PID $($procesoActivoEncontrado.Id)) se ha detectado como 'No Responde'." -ForegroundColor Yellow
                Write-Host "$(Get-Date): Forzando reinicio..." -ForegroundColor Yellow
                Stop-Process -Id $procesoActivoEncontrado.Id -Force
                # El bucle se encargará de relanzarlo en el siguiente ciclo al detectarlo como "desaparecido".
            }
        }
    }

    # --- APPS OPCIONALES (GTTS, Ondeon): solo si existe su exe; si no están abiertas, se relanzan ---
    foreach ($app in $appsOpcionales) {
        if (-not (Test-Path $app.Path)) { continue }
        $procApp = Get-Process -Name $app.Proceso -ErrorAction SilentlyContinue
        if (-not $procApp) {
            if (((Get-Date) - $app.UltimoLanzamiento).TotalSeconds -ge $CooldownRelanzarSeg) {
                Write-Host "$(Get-Date): $($app.Nombre) no está en ejecución. Relanzando..." -ForegroundColor Yellow
                try { Start-Process -FilePath $app.Path -WorkingDirectory (Split-Path $app.Path -Parent) } catch { Write-Host "ERROR lanzando $($app.Nombre): $_" }
                $app.UltimoLanzamiento = Get-Date
            }
        }
    }

    # --- Z-ORDER: Unity normal siempre por delante, Signage siempre detrás de los demás Unity ---
    # Se re-detecta Signage en cada vuelta (carpeta con "*publi*"), así un cambio de matrícula en caliente se aplica sin reiniciar.
    # Monopuesto (o todos Signage): ese Unity es el principal y va delante.
    $hwndsNormal = @()
    $hwndsSignage = @()
    foreach ($proceso in $procesosAsegurar) {
        $p = Get-Process -Name $proceso.Name -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -eq $proceso.Path -and $_.MainWindowHandle -ne 0 } |
             Select-Object -First 1
        if ($p) {
            if ($procesosAsegurar.Count -gt 1 -and (Test-EsSignage -PuestoId $proceso.PuestoId)) {
                $hwndsSignage += $p.MainWindowHandle
            } else {
                $hwndsNormal += $p.MainWindowHandle
            }
        }
    }
    if ($hwndsNormal.Count -eq 0 -and $hwndsSignage.Count -gt 0) { $hwndsNormal = $hwndsSignage; $hwndsSignage = @() }

    # Solo se toca el orden si algun Unity normal tiene otra ventana por encima (Signage u otra cosa)
    $hayDesorden = $false
    foreach ($h in $hwndsNormal) {
        if (Test-AlguienPorEncima $h $hwndsNormal) { $hayDesorden = $true; break }
    }
    if ($hayDesorden) {
        foreach ($h in $hwndsNormal) {
            [WinHelpers]::SetWindowPos($h, $HWND_TOPMOST, 0,0,0,0, ($SWP_NOMOVE -bor $SWP_NOSIZE)) | Out-Null
            [WinHelpers]::SetWindowPos($h, $HWND_NOTOPMOST, 0,0,0,0, ($SWP_NOMOVE -bor $SWP_NOSIZE)) | Out-Null
        }
        # Cada Signage justo detrás del primer Unity normal (no al fondo absoluto del sistema)
        if ($hwndsNormal.Count -gt 0) {
            foreach ($hSig in $hwndsSignage) {
                [WinHelpers]::SetWindowPos($hSig, $hwndsNormal[0], 0,0,0,0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE)) | Out-Null
            }
        }
    }

    # --- Apps opcionales marcadas "AlFondo" (Ondeon): ventana al fondo, sin robar foco ---
    foreach ($app in $appsOpcionales) {
        if (-not $app.AlFondo) { continue }
        $pOpc = Get-Process -Name $app.Proceso -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($pOpc) {
            [WinHelpers]::SetWindowPos($pOpc.MainWindowHandle, $HWND_BOTTOM, 0,0,0,0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE)) | Out-Null
        }
    }

    # --- OCULTAR BARRA DE TAREAS: solo si existe y está visible (en el sistema kiosk no existe, no hace nada) ---
    foreach ($clase in @("Shell_TrayWnd", "Shell_SecondaryTrayWnd")) {
        $tray = [WinHelpers]::FindWindow($clase, $null)
        if ($tray -ne [IntPtr]::Zero -and [WinHelpers]::IsWindowVisible($tray)) { [WinHelpers]::ShowWindow($tray, 0) | Out-Null }  # 0 = SW_HIDE
    }

    # --- LATIDO (v2): cada ~3 vueltas (~30 s) el kiosk hace check-in en el
    # servidor de sala. Se lanza sin esperar: si el servidor no responde o
    # el ciclo se alarga reposicionando, la vigilancia nunca se bloquea
    # por el latido.
    $contadorLatido++
    if ($contadorLatido -ge 3) {
        $contadorLatido = 0
        if (Test-Path $ScriptControl) {
            Start-Process "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptControl`" -Latido" -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 10
}
