# PC Doctor v0.6.0 - только чтение. Ничего не удаляет и не меняет.
param([switch]$NoOpen, [switch]$NoServe, [switch]$ServeOnly, [switch]$Mock, [int]$Port = 8765)
$ErrorActionPreference = 'SilentlyContinue'
$sw = [Diagnostics.Stopwatch]::StartNew()
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$script:StepNames = @(); $script:StepStarts = @(); $script:RunStart = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
$script:StepTotal = 10
$script:StepEst = @(5, 6, 4, 8, 10, 5, 42, 6, 8, 4)
try { $prev = Get-Content -LiteralPath (Join-Path $here 'scan-steps.json') -Raw -ErrorAction Stop | ConvertFrom-Json; if (@($prev).Count -eq 10) { $script:StepEst = @($prev | ForEach-Object { [math]::Max(1, [double]$_) }) } } catch { }
function Step($t) {
    Write-Host ("  [{0,3}s] {1}" -f [int]$sw.Elapsed.TotalSeconds, $t) -ForegroundColor Cyan
    $nowMs = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    $script:StepNames += $t; $script:StepStarts += $nowMs
    try {
        $o = [ordered]@{ startedAt = $script:RunStart; idx = $script:StepNames.Count; total = [math]::Max($script:StepTotal, $script:StepNames.Count); step = $t; stepStart = $nowMs; est = $script:StepEst }
        [IO.File]::WriteAllText((Join-Path $here 'scan-run.json'), ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}
function Safe([scriptblock]$b) { try { & $b } catch { } }
function Num($x) { if ($null -eq $x) { $null } else { [math]::Round([double]$x, 1) } }

if ($ServeOnly -and -not $Mock -and -not (Test-Path -LiteralPath (Join-Path $here 'report.html'))) {
    Write-Host '  No report yet, running a scan first (1-3 min).' -ForegroundColor Yellow
    $ServeOnly = $false
}
if ($ServeOnly) {
    . (Join-Path $here 'lib\live.ps1')
    Start-LiveServer $here $Port ([bool]$Mock) (-not $NoOpen) $null
    exit
}

Write-Host ''
Write-Host '  Collecting data. This takes 1-3 minutes.' -ForegroundColor White
Write-Host ''

# ---------- Система ----------
Step 'System and hardware'
$os   = Safe { Get-CimInstance Win32_OperatingSystem }
$cs   = Safe { Get-CimInstance Win32_ComputerSystem }
$cpu  = Safe { Get-CimInstance Win32_Processor | Select-Object -First 1 }
$bat  = Safe { @(Get-CimInstance Win32_Battery) }
$enc  = Safe { Get-CimInstance Win32_SystemEnclosure }
$laptopTypes = @(8, 9, 10, 11, 14, 30, 31, 32)
$desktopTypes = @(3, 4, 5, 6, 7, 13, 15, 16, 23, 24, 35, 36)
$chassisLaptop = $false
foreach ($t in @($enc.ChassisTypes)) { if ($laptopTypes -contains [int]$t) { $chassisLaptop = $true } }
$chassisDesktop = $false
foreach ($t in @($enc.ChassisTypes)) { if ($desktopTypes -contains [int]$t) { $chassisDesktop = $true } }
# корпус надёжнее батареи: ИБП, подключённый по USB, не делает настольный ПК ноутбуком
$isLaptop = $chassisLaptop -or ((@($bat).Count -gt 0) -and -not $chassisDesktop)

$sticks = @(Safe { Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    [ordered]@{ gb = [math]::Round($_.Capacity / 1GB); speed = $_.Speed; configured = $_.ConfiguredClockSpeed
                slot = $_.DeviceLocator; bank = $_.BankLabel; maker = ([string]$_.Manufacturer).Trim(); part = ([string]$_.PartNumber).Trim()
                type = $(switch ([int]$_.SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { $null } }); ff = $(switch ([int]$_.FormFactor) { 8 { 'DIMM' } 12 { 'SODIMM' } default { $null } }) } } })
$memSlots = Safe { (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum }

# нагрузка процессора: 5 замеров по секунде
Step 'CPU load'
$loads = @()
for ($i = 0; $i -lt 5; $i++) {
    $v = Safe { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }
    if ($null -ne $v) { $loads += [double]$v }
    Start-Sleep -Milliseconds 800
}
$cpuLoad = $null
if ($loads.Count -gt 0) { $cpuLoad = [math]::Round(($loads | Measure-Object -Average).Average, 0) }
$topProc = @(Safe { Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
    Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
    Sort-Object PercentProcessorTime -Descending | Select-Object -First 6 |
    ForEach-Object { [ordered]@{ name = $_.Name; cpu = [int][math]::Min(100, [math]::Round([double]$_.PercentProcessorTime / [math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS))); memMB = [int]($_.WorkingSet / 1MB) } } })

# ---------- Graphics card ----------
Step 'Graphics card'
$gpus = @(Safe { Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{ name = $_.Name; driver = $_.DriverVersion; date = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null }) } } })
$nv = $null
$smi = @('nvidia-smi', "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
    Where-Object { (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
if ($smi) {
    $line = Safe { & $smi --query-gpu=name,memory.total,temperature.gpu,utilization.gpu,driver_version,pcie.link.gen.max,pcie.link.width.max,vbios_version,power.max_limit,clocks.max.graphics --format=csv,noheader,nounits | Select-Object -First 1 }
    if ($line) {
        $p = $line -split ',\s*'
        $nv = [ordered]@{ name = $p[0]; vramMB = [int]$p[1]; tempC = [int]$p[2]; util = [int]$p[3]; driver = $p[4]
            pcieGen = $(if ($p.Count -gt 5 -and $p[5] -match '^\d+$') { [int]$p[5] } else { $null }); pcieWidth = $(if ($p.Count -gt 6 -and $p[6] -match '^\d+$') { [int]$p[6] } else { $null })
            vbios = $(if ($p.Count -gt 7) { $p[7] } else { $null }); powerMaxW = $(if ($p.Count -gt 8 -and $p[8] -match '^[\d.]+$') { [math]::Round([double]$p[8]) } else { $null }); clockMaxMHz = $(if ($p.Count -gt 9 -and $p[9] -match '^\d+$') { [int]$p[9] } else { $null }) }
    }
}

# ---------- Disks ----------
Step 'Disks'
$vols = @(Safe { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $letter = $_.DeviceID.Substring(0, 1)
    $media = $null; $health = $null; $bus = $null; $model = $null
    $part = Safe { Get-Partition -DriveLetter $letter }
    if ($part) {
        $pd = Safe { Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1 }
        if ($pd) { $media = [string]$pd.MediaType; $health = [string]$pd.HealthStatus; $bus = [string]$pd.BusType; $model = $pd.FriendlyName }
    }
    [ordered]@{ letter = $_.DeviceID; sizeGB = Num ($_.Size / 1GB); freeGB = Num ($_.FreeSpace / 1GB); fs = $_.FileSystem
                media = $media; health = $health; bus = $bus; model = $model }
} })

# ---------- Кэши из белого списка (только размер, ничего не удаляется) ----------
Step 'Known cache sizes'
$L = $env:LOCALAPPDATA
$knownCaches = @(
    @{ id = 'nv-dx';   name = 'Кэш шейдеров NVIDIA';      path = "$L\NVIDIA\DXCache";                         verdict = 'safe';  why = 'Пересоздаётся при запуске игр. Первый запуск может быть чуть дольше.' },
    @{ id = 'nv-gl';   name = 'Кэш OpenGL NVIDIA';        path = "$L\NVIDIA\GLCache";                         verdict = 'safe';  why = 'Пересоздаётся автоматически.' },
    @{ id = 'temp';    name = 'Временные файлы пользователя'; path = $env:TEMP;                               verdict = 'safe';  why = 'Временные файлы программ. Занятые файлы Windows не даст удалить.' },
    @{ id = 'capcut';  name = 'Кэш CapCut';               path = "$L\CapCut\User Data\Cache";                 verdict = 'safe';  why = 'Временные файлы предпросмотра. Проекты не затрагиваются.' },
    @{ id = 'insta';   name = 'Логи Insta360 Link Controller'; path = "$L\Insta360 Link Controller\log";     verdict = 'safe';  why = 'Журнал работы камеры. Может разрастаться из-за ошибки.' },
    @{ id = 'chrome';  name = 'Кэш Chrome';               path = "$L\Google\Chrome\User Data\Default\Cache";  verdict = 'safe';  why = 'Сайты загрузятся заново, пароли и вкладки не затрагиваются.' },
    @{ id = 'edge';    name = 'Кэш Edge';                 path = "$L\Microsoft\Edge\User Data\Default\Cache"; verdict = 'safe';  why = 'Сайты загрузятся заново, пароли и вкладки не затрагиваются.' },
    @{ id = 'uv';      name = 'Кэш uv (Python)';          path = "$L\uv\cache";                               verdict = 'safe';  why = 'Скачанные пакеты Python. Скачаются заново при необходимости.' },
    @{ id = 'pip';     name = 'Кэш pip';                  path = "$L\pip\Cache";                              verdict = 'safe';  why = 'Скачанные пакеты Python. Скачаются заново при необходимости.' }
)
$caches = @()
foreach ($c in $knownCaches) {
    if (-not (Test-Path -LiteralPath $c.path)) { continue }
    $sum = 0L
    Get-ChildItem -LiteralPath $c.path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
    $caches += [ordered]@{ id = $c.id; name = $c.name; path = $c.path; bytes = [int64]$sum; verdict = $c.verdict; why = $c.why }
}

# ---------- Сеть ----------
Step 'Network adapters'
$adapters = @(Safe { Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|TAP-|Wintun|Hyper-V|Bluetooth|Loopback|VPN|WAN Miniport|vEthernet|VMware|VirtualBox|Npcap' } | ForEach-Object {
    $pm = Safe { (Get-NetAdapterPowerManagement -Name $_.Name).AllowComputerToTurnOffDevice }
    [ordered]@{ name = $_.Name; desc = $_.InterfaceDescription; media = [string]$_.PhysicalMediaType; speed = $_.LinkSpeed
                driver = $_.DriverVersionString; driverDate = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null })
                driverProvider = $_.DriverProvider; powerSaving = [string]$pm; usb = (([string]$_.PnPDeviceID -match '^USB') -or ($_.InterfaceDescription -match 'USB'))
                wifi = (([string]$_.PhysicalMediaType -match '802\.11') -or ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN')) } } })
$gateway = Safe { (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop }

function Ping-Series($target, $n, $delayMs) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $res = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        $ms = -1
        try { $r = $p.Send($target, 1000); if ($r.Status -eq 'Success') { $ms = [int]$r.RoundtripTime } } catch { }
        [void]$res.Add($ms)
        Start-Sleep -Milliseconds $delayMs
    }
    ,@($res.ToArray())
}
$pingGw = @(); $pingNet = @()
if ($gateway) { Step "Пинг до роутера ($gateway), 40 замеров"; $pingGw = Ping-Series $gateway 40 250 }
Step 'Ping to internet (1.1.1.1), 40 samples'
$pingNet = Ping-Series '1.1.1.1' 40 250

Step 'Windows log: Wi-Fi drops in 7 days'
$since = (Get-Date).AddDays(-7)
$wlanDisc = Safe { @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8003; StartTime = $since }).Count }
$wlanFail = Safe { @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8002; StartTime = $since }).Count }

# ---------- Drivers ----------
Step 'Drivers'
$drivers = @(Safe { Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { $_.DeviceName -and @('NET', 'DISPLAY', 'MEDIA', 'BLUETOOTH', 'SYSTEM', 'HDC') -contains $_.DeviceClass } |
    Where-Object { $_.DeviceClass -ne 'SYSTEM' -or $_.DeviceName -match 'AMD|Intel|Chipset|PSP|SMBus|GPIO' } |
    Sort-Object DeviceClass, DeviceName | Select-Object -First 70 | ForEach-Object {
        [ordered]@{ name = $_.DeviceName; class = $_.DeviceClass; version = $_.DriverVersion
                    date = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null })
                    provider = $_.DriverProviderName; signed = [bool]$_.IsSigned; id = [string]$_.DeviceID } } })
# Одна и та же версия видеодрайвера иногда приходит из двух WMI-классов с датами, где перепутаны день и месяц (2026-11-07 и 2026-07-11).
# Если даты ровно зеркальны и версии совпадают, берём ту, что не в будущем и позже (это дата пакета; драйвер на вкладке не старит ложно).
foreach ($d in $drivers) {
    if ($d.class -ne 'DISPLAY' -or -not $d.date) { continue }
    $g = @($gpus | Where-Object { $_.driver -and $_.driver -eq $d.version -and $_.date -and $_.date -ne $d.date }) | Select-Object -First 1
    if (-not $g) { continue }
    try {
        $x = [datetime]::ParseExact($d.date, 'yyyy-MM-dd', $null); $y = [datetime]::ParseExact($g.date, 'yyyy-MM-dd', $null)
        if ($x.Year -eq $y.Year -and $x.Month -eq $y.Day -and $x.Day -eq $y.Month) {
            $best = @($x, $y | Where-Object { $_ -le (Get-Date).Date.AddDays(1) } | Sort-Object -Descending) | Select-Object -First 1
            if ($best) { $d.date = $best.ToString('yyyy-MM-dd') }
        }
    } catch { }
}
$problemDevices = @(Safe { Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' | ForEach-Object {
    [ordered]@{ name = $_.Name; code = [int]$_.ConfigManagerErrorCode } } })

# ---------- Power, startup, battery ----------
Step 'Power, startup, battery'
$plan = Safe { (powercfg /getactivescheme) -join ' ' }
$planName = $null
if ($plan -match '\((.+)\)') { $planName = $Matches[1] }
$startup = @(Safe { Get-CimInstance Win32_StartupCommand | ForEach-Object { ([string]$_.Name).Trim() } | Select-Object -Unique })
$battery = $null
if ($isLaptop) {
    $full = Safe { (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity }
    $design = Safe { (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity }
    $cycles = Safe { (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount | Select-Object -First 1).CycleCount }
    $onAc = Safe { (@($bat)[0].BatteryStatus) -eq 2 }
    $battery = [ordered]@{ fullmWh = $full; designmWh = $design; cycles = $cycles; onAC = $onAc; chargePct = Safe { @($bat)[0].EstimatedChargeRemaining } }
}

# ---------- Сборка ----------
$data = [ordered]@{
    version = '0.6.0'
    scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    scanSeconds = [int]$sw.Elapsed.TotalSeconds
    computer = [ordered]@{ name = $cs.Name; model = $cs.Model; os = $os.Caption; isLaptop = $isLaptop
                           cpu = $cpu.Name; cores = $cpu.NumberOfCores; threads = $cpu.NumberOfLogicalProcessors
                           ramGB = $(if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB) } else { $null })
                           memSlots = $memSlots; sticks = $sticks }
    cpuLoad = $cpuLoad
    topProcesses = $topProc
    gpus = $gpus
    nvidia = $nv
    volumes = $vols
    caches = $caches
    network = [ordered]@{ adapters = $adapters; gateway = $gateway; pingGateway = $pingGw; pingInternet = $pingNet
                          wlanDisconnects7d = $wlanDisc; wlanFailures7d = $wlanFail }
    drivers = $drivers
    problemDevices = $problemDevices
    powerPlan = $planName
    startupCount = @($startup).Count
    startup = @($startup | Select-Object -First 20)
    battery = $battery
}
$json = $data | ConvertTo-Json -Depth 8 -Compress
$json = $json -replace '</', '<\/'

$utf8 = New-Object System.Text.UTF8Encoding($false)
$tplPath = Join-Path $here 'app\report.template.html'
$outHtml = Join-Path $here 'report.html'
$outJson = Join-Path $here 'data.json'
[IO.File]::WriteAllText($outJson, $json, $utf8)
$tpl = [IO.File]::ReadAllText($tplPath, $utf8)
$tpl = $tpl.Replace('/*__DATA__*/null', $json)
[IO.File]::WriteAllText($outHtml, $tpl, $utf8)
try {
    $endMs = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    $dur = @(); for ($i = 0; $i -lt $script:StepStarts.Count; $i++) { $e2 = $(if ($i + 1 -lt $script:StepStarts.Count) { $script:StepStarts[$i + 1] } else { $endMs }); $dur += [math]::Round(($e2 - $script:StepStarts[$i]) / 1000, 1) }
    if ($dur.Count -eq 10) { [IO.File]::WriteAllText((Join-Path $here 'scan-steps.json'), ($dur | ConvertTo-Json -Compress), $utf8) }
} catch { }

Write-Host ''
Write-Host "  Done in $([int]$sw.Elapsed.TotalSeconds) sec. Report: $outHtml" -ForegroundColor Green
if ($NoServe) { if (-not $NoOpen) { Start-Process $outHtml }; exit }
. (Join-Path $here 'lib\live.ps1')
Start-LiveServer $here $Port ([bool]$Mock) (-not $NoOpen) $gateway
