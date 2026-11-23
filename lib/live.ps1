# PC Doctor: живые датчики и локальный сервер. Только чтение, слушает только 127.0.0.1.
$script:lhm = $null
$script:lhmNote = ''
$script:isAdmin = $false
$script:pg = @{}
# история замеров для вердикта «кто виноват»: последние ~10 минут по трём участкам
$script:NetRing = @{ gw = (New-Object 'System.Collections.Generic.List[int]'); isp = (New-Object 'System.Collections.Generic.List[int]'); inet = (New-Object 'System.Collections.Generic.List[int]') }
$script:NdCache = $null; $script:NdAt = [datetime]'2000-01-01'
$script:cache = $null
$script:cacheAt = [datetime]::MinValue
$script:scanProc = $null
$script:t0 = Get-Date
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'actions.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'disk.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'games.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'fans.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'sessions.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assistant.ps1')

function LvNum($x) { if ($null -eq $x) { return $null }; try { return [math]::Round([double]$x, 1) } catch { return $null } }

function Init-Sensors($Here) {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $script:isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $script:isAdmin = $false }
    $lib = Join-Path $Here 'lib'
    $script:lhmErr = ''
    try {
        # файлы из скачанного архива могут быть помечены Windows как «из интернета»: снимаем метку только с наших DLL
        Get-ChildItem -LiteralPath $lib -Filter *.dll | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch { } }
        $failed = @()
        Get-ChildItem -LiteralPath $lib -Filter *.dll | Sort-Object Name | ForEach-Object {
            try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch { $failed += ($_.Name + ': ' + $_.Exception.Message) }
        }
        $c = New-Object LibreHardwareMonitor.Hardware.Computer
        $c.IsCpuEnabled = $true
        $c.IsGpuEnabled = $true
        $c.IsMotherboardEnabled = $true
        $c.IsControllerEnabled = $true
        try { $c.Open() } catch { $script:lhmErr = 'Open: ' + $_.Exception.Message }
        $script:lhm = $c
    } catch {
        $script:lhm = $null
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m += ' / ' + $_.Exception.InnerException.Message }
        $script:lhmErr = $m
        $script:lhmNote = 'Модуль датчиков не загрузился: ' + $m
        Write-Host ('  Sensors: module not loaded. ' + $m) -ForegroundColor Yellow
        foreach ($f in $failed) { Write-Host ('    ' + $f) -ForegroundColor DarkGray }
    }
    if ($script:lhmErr -and $null -ne $script:lhm) { Write-Host ('  Sensors: ' + $script:lhmErr) -ForegroundColor Yellow }
}

function Read-HwNode($hw, $o) {
    try { $hw.Update() } catch { }
    $ht = [string]$hw.HardwareType
    foreach ($s in $hw.Sensors) {
        if ($null -eq $s.Value) { continue }
        $st = [string]$s.SensorType
        $v = [double]$s.Value
        $n = [string]$s.Name
        if ($ht -eq 'Cpu') {
            if ($st -eq 'Temperature') { $o.cpuTemps[$n] = $v }
            elseif ($st -eq 'Clock' -and $n -match '^(Core|CPU Core) #\d+') { $o.cpuClocks += $v }
            elseif ($st -eq 'Power' -and $n -match 'Package') { $o.cpuPower = $v }
        } elseif ($ht -match '^Gpu') {
            if ($st -eq 'Fan') { $o.gpuFanRpm = $v }
            elseif ($st -eq 'Temperature' -and $n -match 'Hot Spot|Junction') { $o.gpuHot = $v }
            elseif ($st -eq 'Temperature' -and $n -match 'Core' -and $null -eq $o.gpuCore) { $o.gpuCore = $v }
        } else {
            if ($st -eq 'Fan' -and $v -gt 0) { $o.fans += [ordered]@{ name = $n; rpm = [int]$v } }
            elseif ($st -eq 'Temperature' -and $v -gt 0 -and $v -lt 120) { $o.temps += [ordered]@{ name = $n; c = (LvNum $v) } }
        }
    }
    foreach ($sub in $hw.SubHardware) { Read-HwNode $sub $o }
}

function Read-Lhm {
    $o = @{ cpuTemps = @{}; cpuClocks = @(); cpuPower = $null; fans = @(); temps = @(); gpuFanRpm = $null; gpuHot = $null; gpuCore = $null }
    if ($null -eq $script:lhm) { return $o }
    try { foreach ($hw in $script:lhm.Hardware) { Read-HwNode $hw $o } } catch { }
    return $o
}

function Get-NvSmi {
    if ($null -ne $script:smi) { return $script:smi }
    $script:smi = @('nvidia-smi', "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") |
        Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($null -eq $script:smi) { $script:smi = '' }
    return $script:smi
}

function Ping-Tick($key, $target, [int]$ttl = 0) {
    # ttl > 0: «трассировка одного узла» — отвечает n-й узел на пути к $target (так меряется первый узел провайдера)
    if (-not $script:pg.ContainsKey($key)) { $script:pg[$key] = @{ task = $null; last = $null; fresh = $false; addr = '' } }
    $st = $script:pg[$key]
    if ($null -ne $st.task -and $st.task.IsCompleted) {
        try {
            $r = $st.task.Result
            if ($r.Status -eq 'Success' -or ($ttl -gt 0 -and $r.Status -eq 'TtlExpired')) {
                $st.last = [int]$r.RoundtripTime
                if ($ttl -gt 0 -and $null -ne $r.Address) { $st.addr = [string]$r.Address }
            } else { $st.last = -1 }
        } catch { $st.last = -1 }
        $st.fresh = $true
        $st.task = $null
    }
    if ($null -eq $st.task -and $target) {
        try {
            if ($ttl -gt 0) {
                $o = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
                $st.task = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($target, 1000, (New-Object byte[] 32), $o)
            } else { $st.task = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($target, 1000) }
        } catch { }
    }
    return $st.last
}

function NetRing-Add($key, $val) {
    if ($null -eq $val) { return }
    $l = $script:NetRing[$key]
    $l.Add([int]$val)
    if ($l.Count -gt 600) { $l.RemoveAt(0) }
}
function NetRing-Collect {
    # в историю попадает только свежий результат, а не повтор прошлого значения
    foreach ($k in 'gw', 'isp', 'inet') {
        if (-not $script:pg.ContainsKey($k)) { continue }
        $st = $script:pg[$k]
        if ($st.fresh -and $null -ne $st.last) { NetRing-Add $k $st.last }
        $st.fresh = $false
    }
}
function Net-Stats($list, [int]$take = 120) {
    $a = @($list)
    if ($a.Count -gt $take) { $a = @($a[($a.Count - $take)..($a.Count - 1)]) }
    $n = $a.Count
    if ($n -eq 0) { return $null }
    $ok = @($a | Where-Object { $_ -ge 0 } | Sort-Object)
    $med = $null; $p95 = $null; $mx = $null
    if ($ok.Count) {
        $med = $ok[[int][math]::Floor(($ok.Count - 1) * 0.5)]
        $p95 = $ok[[int][math]::Floor(($ok.Count - 1) * 0.95)]
        $mx = $ok[$ok.Count - 1]
    }
    return [ordered]@{ n = $n; loss = [math]::Round((($n - $ok.Count) / $n) * 100, 1); med = $med; p95 = $p95; max = $mx }
}
function Net-Diag {
    # вердикт по последним ~120 замерам (около 2 минут): дом (Wi‑Fi/роутер) → следующий узел за роутером → интернет
    $g = Net-Stats $script:NetRing['gw']; $i = Net-Stats $script:NetRing['isp']; $w = Net-Stats $script:NetRing['inet']
    $addr = ''; if ($script:pg.ContainsKey('isp')) { $addr = [string]$script:pg['isp'].addr }
    $priv = ($addr -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)')
    $v = [ordered]@{ code = 'wait'; title = 'Собираю данные'; text = 'Нужно около 20 секунд замеров.'; tip = ''; isp = 'ok' }
    $gwKnown = ($script:MockMode -or ($script:Gateway -and ([string]$script:Gateway -ne '0.0.0.0')))
    if (-not $gwKnown) {
        $v = [ordered]@{ code = 'nogw'; title = 'Не нашёл роутер'; text = 'Не удалось определить адрес роутера (так бывает при VPN или подключении через модем). Диагностика по участкам недоступна.'; tip = 'Отключите VPN и перезапустите программу.'; isp = 'silent' }
    } elseif ($null -ne $g -and $g.n -ge 20) {
        $ispUsable = ($null -ne $i -and $i.n -ge 40 -and $i.loss -lt 90 -and $null -ne $i.med)
        $gwSilent = ($g.loss -ge 95)
        $inetSilent = ($null -ne $w -and $w.n -ge 20 -and $w.loss -ge 95)
        $gwBad = (-not $gwSilent) -and (($g.loss -ge 2) -or ($null -ne $g.p95 -and $g.p95 -ge 80) -or ($null -ne $g.med -and $g.med -ge 30))
        $inetBad = ($null -ne $w) -and (-not $inetSilent) -and (($w.loss -ge 3) -or ($null -ne $w.p95 -and $null -ne $w.med -and $w.p95 -ge 150 -and ($w.p95 - $w.med) -ge 60))
        # потери на промежуточном узле считаются, только если они «доходят» до интернета; иначе узел просто не любит отвечать на проверки
        $inetShaky = ($null -ne $w) -and ($w.n -ge 40) -and (($w.loss -ge 2) -or ($null -ne $w.p95 -and $null -ne $w.med -and ($w.p95 - $w.med) -ge 60))
        $ispBad = $ispUsable -and (($i.loss -ge 3) -or ($null -ne $i.p95 -and $i.p95 -ge 100)) -and $inetShaky
        $who = $(if ($priv) { 'на следующем узле за роутером (похоже на модем или второй роутер)' } else { 'на первом узле провайдера' })
        if ($inetSilent) {
            $v = [ordered]@{ code = 'blocked'; title = 'Интернет не отвечает на проверки'; text = 'Проверочные запросы до 1.1.1.1 не проходят. Возможно, в вашей сети запрещён ping. Вывод по участкам невозможен.'; tip = '' }
        } elseif ($gwBad) {
            $v = [ordered]@{ code = 'local'; title = 'Проблема между компьютером и роутером'
                text = ('До роутера потери ' + $g.loss + ' %, пики до ' + $g.max + ' мс. Это ваш Wi‑Fi, кабель или сам роутер, а не интернет-провайдер.')
                tip = 'Подключитесь кабелем или подойдите ближе к роутеру, переключитесь на 5 ГГц, перезагрузите роутер.' }
        } elseif ($ispBad) {
            $v = [ordered]@{ code = 'isp'; title = $(if ($priv) { 'Проблема сразу за роутером' } else { 'Проблема сразу за роутером, у провайдера' })
                text = ('Дома связь ровная' + $(if ($gwSilent) { '' } else { ' (до роутера ' + $g.med + ' мс)' }) + ', а ' + $who + ' потери ' + $i.loss + ' %, пики до ' + $i.max + ' мс; такие же сбои видны и до интернета.')
                tip = $(if ($priv) { 'Проверьте модем и кабель до него, перезагрузите оборудование.' } else { 'Скорее всего линия или оборудование провайдера. Сохраните эти цифры и покажите провайдеру.' }) }
        } elseif ($inetBad) {
            $v = [ordered]@{ code = 'far'; title = 'Дома всё ровно, проблема дальше'
                text = ('До интернета потери ' + $w.loss + ' %, пики до ' + $w.max + ' мс.' + $(if ($gwSilent) { ' Роутер не отвечает на проверки, поэтому домашний участок оценить нельзя.' } else { ' Роутер' + $(if ($ispUsable) { ' и ближайший узел' } else { '' }) + ' в порядке.' }))
                tip = 'Причина дальше по маршруту. Если лагает одна игра, возможно, виноват её сервер.' }
        } else {
            $m = 'Сеть в порядке'
            if ($gwSilent) { $m += ': роутер не отвечает на проверки, но интернет работает ровно' } elseif ($null -ne $g.med) { $m += ': до роутера ' + $g.med + ' мс' }
            if ($null -ne $w -and $null -ne $w.med) { $m += ', до интернета ' + $w.med + ' мс' }
            $v = [ordered]@{ code = 'ok'; title = 'Сеть в порядке'; text = ($m + '. Если игра лагает, причина не в сети.'); tip = '' }
        }
        $v.isp = $(if ($ispUsable) { 'ok' } else { 'silent' })
    }
    return [ordered]@{ verdict = $v; gw = $g; isp = $i; inet = $w; ispAddr = $addr; ispPrivate = [bool]$priv }
}
function Net-DiagCached {
    if (($null -eq $script:NdCache) -or (((Get-Date) - $script:NdAt).TotalSeconds -ge 3)) { $script:NdCache = Net-Diag; $script:NdAt = Get-Date }
    return $script:NdCache
}

function Get-MockLive {
    $t = ((Get-Date) - $script:t0).TotalSeconds
    $wob = { param($base, $amp, $f, $ph) [math]::Round($base + $amp * [math]::Sin($t * $f + $ph) + 2 * [math]::Sin($t * 3.7 + $ph), 1) }
    $cores = @(); for ($i = 0; $i -lt 12; $i++) { $cores += [math]::Max(1, [math]::Min(100, (& $wob 22 20 (0.4 + $i * 0.05) $i))) }
    $gl = [math]::Max(0, [math]::Min(100, (& $wob 78 15 0.25 1)))
    # сценарий сети для проверки интерфейса: PCD_MOCK_NET = ok | gw | isp | far
    $sc = [string]$env:PCD_MOCK_NET; if (-not $sc) { $sc = 'ok' }
    $ti = [int][math]::Floor($t)
    $mg = [int][math]::Max(1, (& $wob 4 2 0.5 15)); $mi = [int][math]::Max(5, (& $wob 11 2 0.5 17)); $mw = [int][math]::Max(10, (& $wob 38 6 0.4 16))
    if ($sc -eq 'gw') { if ($ti % 4 -eq 0) { $mg = 95 }; if ($ti % 7 -eq 0) { $mg = -1 }; if ($ti % 4 -eq 0) { $mi += 90; $mw += 90 } }
    if ($sc -eq 'isp') { if ($ti % 6 -eq 0) { $mi = -1 }; if ($ti % 5 -eq 0) { $mi = 140 }; if ($ti % 9 -eq 0) { $mw = -1 } }
    if ($sc -eq 'far') { if ($ti % 8 -eq 0) { $mw = -1 }; if ($ti % 5 -eq 0) { $mw = 210 } }
    $mp = [ordered]@{ gw = $mg; isp = $mi; inet = $mw }
    if ($script:MockNdT -ne $ti) { $script:MockNdT = $ti; NetRing-Add 'gw' $mg; NetRing-Add 'isp' $mi; NetRing-Add 'inet' $mw }
    return [ordered]@{
        t = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
        cpu = [ordered]@{ load = [math]::Round(($cores | Measure-Object -Average).Average, 0); cores = $cores; mhz = (& $wob 4050 250 0.3 0); temp = (& $wob 58 8 0.2 2); power = (& $wob 52 12 0.3 3) }
        gpu = [ordered]@{ name = 'NVIDIA GeForce RTX 4060 Ti'; load = $gl; temp = (& $wob 62 6 0.15 4); fanPct = (& $wob 42 8 0.2 5); fanRpm = $null; memUsedMB = 5200 + [int](400 * [math]::Sin($t / 5)); memTotalMB = 8188; clock = (& $wob 2500 150 0.3 6); memClock = 9001; power = (& $wob 120 30 0.25 7); powerLimit = 160; hot = $null }
        ram = [ordered]@{ usedGB = (& $wob 19.5 0.8 0.1 8); totalGB = 31.9; pct = 61 }
        disks = @([ordered]@{ name = 'C:'; busy = [math]::Max(0, (& $wob 12 10 0.5 9)); readMBs = [math]::Max(0, (& $wob 40 30 0.5 9)); writeMBs = [math]::Max(0, (& $wob 15 12 0.4 10)) },
                  [ordered]@{ name = 'D:'; busy = [math]::Max(0, (& $wob 3 3 0.4 11)); readMBs = [math]::Max(0, (& $wob 4 4 0.4 12)); writeMBs = 0.2 })
        net = [ordered]@{ name = 'Wi-Fi'; downMbps = [math]::Max(0, (& $wob 40 30 0.35 13)); upMbps = [math]::Max(0, (& $wob 6 4 0.3 14)) }
        topio = @(Get-TopIO)
        ping = $mp; netdiag = (Net-DiagCached)
        fans = @([ordered]@{ name = 'CPU Fan'; rpm = [int](& $wob 1250 150 0.2 17) }, [ordered]@{ name = 'Chassis Fan #1'; rpm = [int](& $wob 880 60 0.2 18) })
        temps = @([ordered]@{ name = 'Motherboard'; c = 38 }, [ordered]@{ name = 'VRM'; c = 52 })
        sensors = [ordered]@{ lhm = $true; admin = $true; note = 'Тестовые данные (режим -Mock).' }
    }
}

function Get-TopIO {
    if ($script:MockMode) { return @([ordered]@{ name = 'MsMpEng'; mbs = 38.2 }, [ordered]@{ name = 'chrome'; mbs = 12.4 }, [ordered]@{ name = 'SearchIndexer'; mbs = 6.1 }) }
    $now = Get-Date
    if ($script:topIoAt -and ($now - $script:topIoAt).TotalSeconds -lt $(if ($script:eco) { 30 } else { 4 })) { return $script:topIo }
    $r = @()
    try {
        $r = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop | Where-Object { $_.Name -notmatch '^(_Total|Idle)$' -and $_.IODataBytesPersec -gt 1MB } |
            Sort-Object IODataBytesPersec -Descending | Select-Object -First 3 | ForEach-Object {
                [ordered]@{ name = (([string]$_.Name) -replace '#\d+$', ''); mbs = (LvNum ($_.IODataBytesPersec / 1MB)) } })
    } catch { }
    $script:topIo = $r; $script:topIoAt = $now
    return $r
}

# Экономный режим: пока идёт игра из списка, программа реже опрашивает систему и не делает тяжёлых запросов.
function Get-EcoMode {
    if ($script:MockMode) { return $false }
    $n = Get-Date
    if ($null -ne $script:ecoAt -and ($n - $script:ecoAt).TotalSeconds -lt 8) { return [bool]$script:eco }
    $e = $false
    try {
        $st = Games-Load
        if ($st.active) { $e = $true }
        else { foreach ($g in @($st.games)) { if (@(Game-Procs $g).Count -gt 0) { $e = $true; break } } }
    } catch { }
    $script:eco = $e; $script:ecoAt = $n
    return $e
}
function Get-Live($gateway, [bool]$Mock) {
    if ($Mock) { return Get-MockLive }
    $now = Get-Date
    $ecoNow = Get-EcoMode
    $ttl = if ($ecoNow) { 3000 } else { 700 }
    if ($null -ne $script:cache -and ($now - $script:cacheAt).TotalMilliseconds -lt $ttl) { return $script:cache }

    $swLive = [Diagnostics.Stopwatch]::StartNew()
    # процессор: счётчики производительности (быстро); если не вышло, запасной путь через WMI
    $cores = @(); $load = $null
    if ($null -eq $script:cpuPc -and -not $script:cpuPcFail) {
        try {
            $cat = New-Object Diagnostics.PerformanceCounterCategory('Processor')
            $names = @($cat.GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object { [int]$_ })
            $tot = New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
            $cs = @($names | ForEach-Object { New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', $_) })
            [void]$tot.NextValue(); foreach ($c in $cs) { [void]$c.NextValue() }
            $script:cpuPc = [pscustomobject]@{ total = $tot; cores = $cs }
        } catch { $script:cpuPcFail = $true }
    }
    if ($null -ne $script:cpuPc) {
        try {
            $load = [math]::Round([double]$script:cpuPc.total.NextValue(), 1)
            $cores = @($script:cpuPc.cores | ForEach-Object { [int][math]::Round([double]$_.NextValue()) })
        } catch { $script:cpuPc = $null; $script:cpuPcFail = $true; $load = $null; $cores = @() }
    }
    if ($null -eq $load) {
    try {
        $rows = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor
        foreach ($r in $rows) {
            if ($r.Name -eq '_Total') { $load = [double]$r.PercentProcessorTime }
        }
        $cores = @($rows | Where-Object { $_.Name -ne '_Total' } | Sort-Object { [int]($_.Name -replace '\D', '') } | ForEach-Object { [int]$_.PercentProcessorTime })
    } catch { }
    }
    $lh = Read-Lhm
    $cpuTemp = $null
    foreach ($k in @('Core (Tctl/Tdie)', 'CPU Package', 'Core Max', 'CPU (Tdie)', 'Core (Tdie)')) { if ($null -eq $cpuTemp -and $lh.cpuTemps.ContainsKey($k)) { $cpuTemp = $lh.cpuTemps[$k] } }
    if ($null -eq $cpuTemp -and $lh.cpuTemps.Count -gt 0) { $cpuTemp = ($lh.cpuTemps.Values | Measure-Object -Maximum).Maximum }
    $mhz = $null
    if ($lh.cpuClocks.Count -gt 0) { $mhz = ($lh.cpuClocks | Measure-Object -Average).Average }
    else {
        if ($null -eq $script:mhzC -or ($now - $script:mhzAt).TotalSeconds -ge 5) { try { $script:mhzC = (Get-CimInstance Win32_Processor | Select-Object -First 1).CurrentClockSpeed; $script:mhzAt = $now } catch { } }
        $mhz = $script:mhzC
    }

    # память
    $ram = $null
    if ($null -ne $script:ramC -and ($now - $script:ramAt).TotalSeconds -lt 3) { $ram = $script:ramC } else {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $tot = [double]$os.TotalVisibleMemorySize / 1MB; $free = [double]$os.FreePhysicalMemory / 1MB
        $ram = [ordered]@{ usedGB = (LvNum ($tot - $free)); totalGB = (LvNum $tot); pct = [int](($tot - $free) / $tot * 100) }
        $script:ramC = $ram; $script:ramAt = $now
    } catch { }
    }

    # видеокарта
    $gpu = $null
    $smi = Get-NvSmi
    if ($smi) {
        try {
            $line = & $smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,clocks.gr,clocks.mem,power.draw,power.limit,fan.speed --format=csv,noheader,nounits | Select-Object -First 1
            $p = @($line -split ',\s*')
            $n = { param($i) $v = $null; if ($i -lt $p.Count) { $s = $p[$i].Trim(); if ($s -match '^[\d.]+$') { $v = [double]$s } }; $v }
            $gpu = [ordered]@{ name = $p[0]; temp = (& $n 1); load = (& $n 2); memUsedMB = (& $n 3); memTotalMB = (& $n 4); clock = (& $n 5); memClock = (& $n 6); power = (& $n 7); powerLimit = (& $n 8); fanPct = (& $n 9); fanRpm = $lh.gpuFanRpm; hot = $lh.gpuHot }
        } catch { }
    }

    # диски
    $disks = @()
    if ($null -ne $script:dskC -and ($now - $script:dskAt).TotalSeconds -lt 2) { $disks = $script:dskC } else {
    try {
        $disks = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk | Where-Object { $_.Name -match '^[A-Z]:$' } | ForEach-Object {
            [ordered]@{ name = $_.Name; busy = [math]::Min(100, [double]$_.PercentDiskTime); readMBs = (LvNum ($_.DiskReadBytesPersec / 1MB)); writeMBs = (LvNum ($_.DiskWriteBytesPersec / 1MB)) } })
        $script:dskC = $disks; $script:dskAt = $now
    } catch { }
    }

    # сеть
    $net = $null
    try {
        $ni = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo|Pseudo' } | Sort-Object BytesTotalPersec -Descending | Select-Object -First 1
        if ($ni) { $net = [ordered]@{ name = [string]$ni.Name; downMbps = (LvNum ($ni.BytesReceivedPersec * 8 / 1e6)); upMbps = (LvNum ($ni.BytesSentPersec * 8 / 1e6)) } }
    } catch { }
    $png = [ordered]@{ gw = (Ping-Tick 'gw' $gateway); isp = (Ping-Tick 'isp' '1.1.1.1' 2); inet = (Ping-Tick 'inet' '1.1.1.1') }
    NetRing-Collect
    $topio = @()
    if (@($disks | Where-Object { $_.busy -ge 40 }).Count -gt 0) { $topio = @(Get-TopIO) }

    # подсказка про датчики
    $note = $script:lhmNote
    if ($null -ne $script:lhm -and $null -eq $cpuTemp) {
        if (-not $script:isAdmin) { $note = 'Температура процессора и вентиляторы материнской платы читаются только при запуске от администратора (файл Admin.bat).' }
        else { $note = 'Температура процессора недоступна. Для Ryzen обычно нужен драйвер PawnIO (pawnio.eu), он ставится отдельно.' }
    }
    $res = [ordered]@{
        t = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
        cpu = [ordered]@{ load = (LvNum $load); cores = $cores; mhz = (LvNum $mhz); temp = (LvNum $cpuTemp); power = (LvNum $lh.cpuPower) }
        gpu = $gpu; ram = $ram; disks = $disks; topio = $topio; net = $net; ms = [int]$swLive.ElapsedMilliseconds; ping = $png; gwAddr = [string]$gateway; netdiag = (Net-DiagCached)
        fans = $lh.fans; temps = $lh.temps
        eco = $ecoNow
        sensors = [ordered]@{ lhm = ($null -ne $script:lhm); admin = $script:isAdmin; note = $note }
    }
    $script:cache = $res; $script:cacheAt = $now
    return $res
}

function Send-Bytes($ctx, [byte[]]$bytes, $type, $code) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.Headers.Add('X-Content-Type-Options', 'nosniff')
    $res.Headers.Add('X-Frame-Options', 'DENY')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Read-Body($req) {
    try { $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); if ($t) { return ($t | ConvertFrom-Json) } } catch { }
    return $null
}
function Send-Json($ctx, $obj, $utf8) {
    $j = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Bytes $ctx ($utf8.GetBytes($j)) 'application/json; charset=utf-8' 200
}

function Start-LiveServer($Here, $Port, [bool]$Mock, [bool]$OpenBrowser, $gateway) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:AppDir = $Here
    if (-not $Mock) {
        # личные данные (ключ помощника, журнал, история, список игр) живут в профиле пользователя, а не в папке программы:
        # так они переживают замену папки новой версией. При первом запуске переносим то, что лежит рядом с программой.
        try {
            $dd = Join-Path $env:LOCALAPPDATA 'PCDoctor'
            if ($env:LOCALAPPDATA) {
                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                $mv = @('settings.json', 'journal.json', 'history.json', 'events.json', 'games.json', 'fans.json', 'rec.json', 'sessions.json') + @(Get-ChildItem -LiteralPath $Here -Filter 'bigfiles-*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                foreach ($f in $mv) { $src = Join-Path $Here $f; $dst = Join-Path $dd $f; if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue } }
                $ic = Join-Path $Here 'icons'; if ((Test-Path -LiteralPath $ic) -and -not (Test-Path -LiteralPath (Join-Path $dd 'icons'))) { Copy-Item -LiteralPath $ic -Destination (Join-Path $dd 'icons') -Recurse -Force -ErrorAction SilentlyContinue }
                $script:AppDir = $dd
            }
        } catch { $script:AppDir = $Here }
    }
    $script:MockMode = $Mock
    $dj = Json-Read (Join-Path $Here 'data.json') $null
    $isLaptop = $false; if ($dj -and $dj.computer) { $isLaptop = [bool]$dj.computer.isLaptop }
    Init-Sensors $Here
    if (-not $gateway) { try { $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { } }
    $script:Gateway = $gateway
    $listener = $null; $url = $null
    for ($p = $Port; $p -lt ($Port + 10); $p++) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$p/")
        try { $l.Start(); $listener = $l; $url = "http://127.0.0.1:$p/"; break } catch { try { $l.Close() } catch { } }
    }
    if ($null -eq $listener) { Write-Host '  Could not open local port. Open report.html directly.' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host "  Live mode: $url" -ForegroundColor Green
    Write-Host "  Data folder: $script:AppDir" -ForegroundColor DarkGray
    Write-Host '  Sensors update every second. Close this window or press Ctrl+C to stop.' -ForegroundColor White
    if ($script:isAdmin) { Write-Host '  Running as administrator: CPU temperature and fans are available if the PawnIO driver is installed.' -ForegroundColor DarkGray }
    else { Write-Host '  Without administrator rights CPU temperature may be unavailable (see Admin.bat).' -ForegroundColor DarkGray }
    # низкий приоритет самой программы: игра всегда важнее
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $script:lastGameTick = [DateTime]::UtcNow
    $script:lastFanTick = [DateTime]::UtcNow
    $script:lastSessTick = [DateTime]::UtcNow
    try { Sess-Recover } catch { }
    # после перезапуска программы автоуправление всегда выключено: включайте заново осознанно
    # если прошлый запуск закрыли крестиком при включённом автоуправлении, отдаём вентиляторы плате
    try { $fc = Fans-Cfg; if ($fc.enabled) { if (-not $script:MockMode) { Fans-Release }; $fc.enabled = $false; Fans-CfgSave $fc } } catch { }
    $script:PcdToken = [guid]::NewGuid().ToString('N')
    # закрытие окна консоли крестиком: успеть вернуть вентиляторы и игровые настройки (Windows даёт около 5 секунд)
    try {
        if (-not ('PcdExit' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
public static class PcdExit {
    public static volatile bool Req; public static ManualResetEvent Done = new ManualResetEvent(false);
    delegate bool H(int t); static H h = On;
    [DllImport("kernel32")] static extern bool SetConsoleCtrlHandler(H a, bool b);
    static bool On(int t) { if (t == 2 || t == 5 || t == 6) { Req = true; Done.WaitOne(4500); return true; } return false; }
    public static void Install() { SetConsoleCtrlHandler(h, true); }
}
'@
        }
        [PcdExit]::Install()
    } catch { }
    if ($OpenBrowser) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList $url } catch { Write-Host ('  Open this address in your browser: ' + $url) -ForegroundColor Yellow } }
    try {
        while ($listener.IsListening) {
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(300)) { if (('PcdExit' -as [type]) -and [PcdExit]::Req) { break }; if (([DateTime]::UtcNow - $script:lastGameTick).TotalSeconds -ge 3) { $script:lastGameTick = [DateTime]::UtcNow; try { Game-Tick $isLaptop } catch { } } if (([DateTime]::UtcNow - $script:lastFanTick).TotalSeconds -ge 2) { $script:lastFanTick = [DateTime]::UtcNow; try { Fans-Tick } catch { } } if (([DateTime]::UtcNow - $script:lastSessTick).TotalSeconds -ge 1) { $script:lastSessTick = [DateTime]::UtcNow; try { Sess-Tick } catch { } } }
            if (('PcdExit' -as [type]) -and [PcdExit]::Req) { break }
            $ctx = $task.Result
            try {
                $req = $ctx.Request
                $hostOk = [string]$req.Headers['Host'] -match '^(127\.0\.0\.1|localhost)(:\d+)?$'
                $path = $req.Url.AbsolutePath
                $og = [string]$req.Headers['Origin']
                if ($hostOk -and $og -and ($og -notmatch '^http://127\.0\.0\.1(:\d+)?$')) { $hostOk = $false }
                if ($path -eq '/favicon.ico') { $ctx.Response.StatusCode = 204; $ctx.Response.Close() }
                elseif (-not $hostOk) { Send-Bytes $ctx ($utf8.GetBytes('forbidden')) 'text/plain' 403 }
                elseif ($path -eq '/' -or $path -eq '/report.html') {
                    # страница каждый раз собирается из свежего шаблона + данных последней проверки,
                    # поэтому после обновления программы старый report.html не мешает
                    $f = Join-Path $Here 'report.html'
                    $tplF = Join-Path $Here 'app\report.template.html'
                    $djF = Join-Path $Here 'data.json'
                    $djOk = $true
                    if (Test-Path -LiteralPath $djF) { try { $null = ([IO.File]::ReadAllText($djF, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) } catch { $djOk = $false } }
                    if (-not $djOk) { Send-Bytes $ctx ($utf8.GetBytes('Файл data.json повреждён. Закройте программу и запустите Start.bat: он сделает новую проверку.')) 'text/plain; charset=utf-8' 500 }
                    elseif ((Test-Path -LiteralPath $tplF) -and (Test-Path -LiteralPath $djF)) {
                        $page = [IO.File]::ReadAllText($tplF, [Text.Encoding]::UTF8).Replace('/*__DATA__*/null', [IO.File]::ReadAllText($djF, [Text.Encoding]::UTF8)).Replace("'X-PCD':'1'", "'X-PCD':'" + $script:PcdToken + "'")
                        Send-Bytes $ctx ($utf8.GetBytes($page)) 'text/html; charset=utf-8' 200
                    }
                    elseif (Test-Path -LiteralPath $f) { Send-Bytes $ctx ([IO.File]::ReadAllBytes($f)) 'text/html; charset=utf-8' 200 }
                    else { Send-Bytes $ctx ($utf8.GetBytes('report.html не найден. Запустите Start.bat.')) 'text/plain; charset=utf-8' 404 }
                }
                elseif ($path -eq '/api/disks') {
                    $dl = @()
                    if (-not $script:MockMode) { try { $dl = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object { [ordered]@{ letter = $_.DeviceID; sizeGB = [math]::Round($_.Size / 1GB, 1); freeGB = [math]::Round($_.FreeSpace / 1GB, 1) } }) } catch { $dl = @() } }
                    Send-Json $ctx @{ disks = $dl } $utf8
                }
                elseif ($path -eq '/api/live') {
                    $j = (Get-Live $gateway $Mock) | ConvertTo-Json -Depth 6 -Compress
                    Send-Bytes $ctx ($utf8.GetBytes($j)) 'application/json; charset=utf-8' 200
                }
                elseif ($path -eq '/api/status') {
                    $busy = ($null -ne $script:scanProc -and -not $script:scanProc.HasExited)
                    $run = $null
                    if ($Mock -and $script:mockScanAt) {
                        $el = ((Get-Date) - $script:mockScanAt).TotalSeconds
                        if ($el -ge 14) { $script:mockScanAt = $null } else {
                            $busy = $true; $idx = [math]::Min(10, [int]($el / 1.4) + 1)
                            $run = [ordered]@{ startedAt = [int64](([datetime]::UtcNow.AddSeconds(-$el) - [datetime]'1970-01-01').TotalMilliseconds); idx = $idx; total = 10; step = 'Mock'; stepStart = [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds); est = @(1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.4) }
                        }
                    }
                    elseif ($busy) { $run = Json-Read (Join-Path $Here 'scan-run.json') $null }
                    Send-Json $ctx ([ordered]@{ scanning = $busy; run = $run }) $utf8
                }
                elseif ($path -eq '/api/rescan' -and $req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken) {
                    $busy = ($null -ne $script:scanProc -and -not $script:scanProc.HasExited)
                    if ($Mock) { if (-not $script:mockScanAt) { $script:mockScanAt = Get-Date } }
                    elseif (-not $busy) {
                        Remove-Item -LiteralPath (Join-Path $Here 'scan-run.json') -ErrorAction SilentlyContinue
                        $script:scanProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Here 'scan.ps1') + '"'), '-NoOpen', '-NoServe')
                    }
                    Send-Bytes $ctx ($utf8.GetBytes('{"started":true}')) 'application/json' 200
                }
                elseif ($path -eq '/api/settings' -and $req.HttpMethod -eq 'GET') { Send-Json $ctx @{ hasKey = (Has-ApiKey) } $utf8 }
                elseif ($path -eq '/api/assistant-result') { Send-Json $ctx (Get-AssistantResult ([string]$req.QueryString['id'])) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/settings') { $b = Read-Body $req; if ($null -eq $b) { Send-Json $ctx @{ ok = $false; error = 'Некорректный запрос' } $utf8 } else { Send-Json $ctx (Set-ApiKey ([string]$b.apiKey)) $utf8 } }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/assistant') { $b = Read-Body $req; Send-Json $ctx (Start-Assistant @($b.messages) $b.context) $utf8 }
                elseif ($path -eq '/api/scan-status') { Send-Json $ctx (Get-DiskScanStatus) $utf8 }
                elseif ($path -eq '/api/bigfiles') { $r = Get-DiskResult ([string]$req.QueryString['drive']); if ($r) { Send-Json $ctx $r $utf8 } else { Send-Json $ctx @{ none = $true } $utf8 } }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/scan-disk') { $b = Read-Body $req; Send-Json $ctx (Start-DiskScan ([string]$b.drive) ([int]$b.minMB)) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/trash') { $b = Read-Body $req; Send-Json $ctx (Trash-Files ([string]$b.drive) @($b.paths) $false) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/stop-trash') { $b = Read-Body $req; Send-Json $ctx (Stop-And-Trash ([string]$b.drive) ([string]$b.path)) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/reveal') { $b = Read-Body $req; Send-Json $ctx @{ ok = (Reveal-File ([string]$b.drive) ([string]$b.path)) } $utf8 }
                elseif ($path -eq '/api/actions') { Send-Json $ctx @(Get-ActionList $isLaptop) $utf8 }
                elseif ($path -eq '/api/overlays') { Send-Json $ctx @(Get-OverlayApps) $utf8 }
                elseif ($path -eq '/api/journal') { Send-Json $ctx @(Journal-Get) $utf8 }
                elseif ($path -eq '/api/history') { Send-Json $ctx @(Json-Read (History-Path) @()) $utf8 }
                elseif ($path -eq '/api/events') { Send-Json $ctx @(Json-Read (Events-Path) @()) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/event') {
                    $b = Read-Body $req
                    Send-Json $ctx (Add-Event ([string]$b.kind) ([string]$b.title) ([string]$b.detail)) $utf8
                }
                elseif ($path -eq '/api/downloads') { Send-Json $ctx (Get-Downloads ([string]$req.QueryString['drive'])) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/trash-downloads') { $b = Read-Body $req; Send-Json $ctx (Trash-Downloads ([string]$b.drive) @($b.paths)) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/reveal-download') { $b = Read-Body $req; Send-Json $ctx @{ ok = (Reveal-Download ([string]$b.drive) ([string]$b.path)) } $utf8 }
                elseif ($path -eq '/api/fans') { Send-Json $ctx (Fans-Status) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/fans-set') { $b = Read-Body $req; Send-Json $ctx (Fans-Set $b) $utf8 }
                elseif ($path -eq '/api/sessions') { Send-Json $ctx (Sess-Status) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/sessions-cfg') { $b = Read-Body $req; Send-Json $ctx (Sess-SetEnabled ([bool]$b.enabled)) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/clear') { $b = Read-Body $req; Send-Json $ctx (Clear-AppData ([string]$b.what)) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/sessions-del') { $b = Read-Body $req; Send-Json $ctx (Sess-Delete ([string]$b.id)) $utf8 }
                elseif ($path -eq '/api/games-found') { Send-Json $ctx (Games-Found) $utf8 }
                elseif ($path -eq '/api/game-icon') { $iid = [string]$req.QueryString['id']; $ib = Game-IconCached $iid; if (-not $ib -and -not $script:MockMode) { $ib = Game-IconBytes $iid }; if ($ib) { $ict = 'image/png'; if ($ib.Length -gt 2 -and $ib[0] -eq 0xFF -and $ib[1] -eq 0xD8) { $ict = 'image/jpeg' }; Send-Bytes $ctx $ib $ict 200 } else { $ctx.Response.StatusCode = 404; $ctx.Response.Close() } }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-add-found') { $b = Read-Body $req; Send-Json $ctx (Game-Add-Found ([string]$b.key) @($b.close) $b.auto) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-launch') { $b = Read-Body $req; Send-Json $ctx (Game-Launch ([string]$b.id)) $utf8 }
                elseif ($path -eq '/api/games') { Send-Json $ctx (Games-Status) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-add') { $b = Read-Body $req; Send-Json $ctx (Game-Add $b.name $b.exe @($b.close) $b.auto) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-update') { $b = Read-Body $req; Send-Json $ctx (Game-Update ([string]$b.id) @($b.close) $b.auto $b.name) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-remove') { $b = Read-Body $req; Send-Json $ctx (Game-Remove ([string]$b.id)) $utf8 }
                elseif ($script:MockMode -and $req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/game-mock') { $b = Read-Body $req; $e = Clean-Exe $b.exe; if ($e) { $script:MockRunning = @($script:MockRunning | Where-Object { $_ -ne $e }); if ($b.on) { $script:MockRunning += $e } }; Game-Tick $isLaptop; Send-Json $ctx (Games-Status) $utf8 }
                elseif ($path -eq '/api/apps') { Send-Json $ctx @(Get-AppList) $utf8 }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/action') {
                    $b = Read-Body $req
                    $script:CleanStep = $(if ($b.step) { [int]$b.step } else { 0 })
                    Send-Json $ctx (Run-Action ([string]$b.id) @($b.ids | Where-Object { $_ }) $isLaptop) $utf8
                }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/undo') {
                    $b = Read-Body $req
                    Send-Json $ctx (Run-Undo ([string]$b.id)) $utf8
                }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/close') {
                    $b = Read-Body $req
                    Send-Json $ctx (Close-App $b.pid) $utf8
                }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/open') {
                    $b = Read-Body $req
                    Send-Json $ctx @{ ok = (Open-Tool ([string]$b.what) ([string]$b.arg)) } $utf8
                }
                elseif ($req.HttpMethod -eq 'POST' -and $req.Headers['X-PCD'] -ceq $script:PcdToken -and $path -eq '/api/snapshot') {
                    $b = Read-Body $req
                    $h = @(Json-Read (History-Path) @())
                    if ($b -and -not ($h | Where-Object { $_.scannedAt -eq $b.scannedAt })) {
                        $h += $b
                        if ($h.Count -gt 60) { $h = $h[($h.Count - 60)..($h.Count - 1)] }
                        Json-Write (History-Path) $h
                    }
                    Send-Json $ctx @{ ok = $true } $utf8
                }
                else { Send-Bytes $ctx ($utf8.GetBytes('not found')) 'text/plain' 404 }
            } catch {
                try { $ctx.Response.Abort() } catch { }
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        try { Fans-Release } catch { }
        try { $ga = (Games-Load).active; if ($ga -and -not $script:MockMode) { Game-Stop $ga } } catch { }
        try { [void](Sess-End 'программа закрыта') } catch { }
        try { if ('PcdExit' -as [type]) { [void][PcdExit]::Done.Set() } } catch { }
        if ($null -ne $script:lhm) { try { $script:lhm.Close() } catch { } }
    }
}
