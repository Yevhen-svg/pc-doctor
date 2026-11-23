# PC Doctor: автоуправление вентиляторами по температуре (через LibreHardwareMonitor, нужны права администратора).
# Безопасность: нижний предел оборотов, 100% при перегреве, возврат управления материнской плате при выключении/ошибке датчика.
$script:FanFloor = 35
$script:FanMock = @{}
$script:FanLast = @{}
$script:FanBad = 0
function Fans-Path { Join-Path $script:AppDir 'fans.json' }
function Fans-Cfg {
    $d = Json-Read (Fans-Path) $null
    $cfg = [ordered]@{ enabled = $false; target = 70; fans = @() }
    if ($d) { $cfg.enabled = [bool]$d.enabled; if ($d.target) { $cfg.target = [int]$d.target }; $cfg.fans = @($d.fans | Where-Object { $_ }) }
    return $cfg
}
function Fans-CfgSave($cfg) { Json-Write (Fans-Path) $cfg }
function Fan-Sensors($hw, $out) {
    $ht = [string]$hw.HardwareType
    if ($ht -ne 'Cpu' -and $ht -notmatch '^Gpu') {
        try { $hw.Update() } catch { }
        foreach ($s in $hw.Sensors) { if ([string]$s.SensorType -eq 'Control' -and $null -ne $s.Control) { $out += , $s } }
    }
    foreach ($sub in $hw.SubHardware) { $out = Fan-Sensors $sub $out }
    return $out
}
function Fans-Controls {
    if ($script:MockMode) {
        return @(@{ id = '/mock/fan1'; name = 'Вентилятор процессора (CPU Fan)'; pct = [int]$(if ($script:FanMock['/mock/fan1']) { $script:FanMock['/mock/fan1'] } else { 42 }) },
                 @{ id = '/mock/fan2'; name = 'Корпусной вентилятор #1'; pct = [int]$(if ($script:FanMock['/mock/fan2']) { $script:FanMock['/mock/fan2'] } else { 38 }) })
    }
    $o = @(); if ($null -eq $script:lhm) { return $o }
    $list = @(); try { foreach ($hw in $script:lhm.Hardware) { $list = Fan-Sensors $hw $list } } catch { }
    foreach ($s in $list) { $o += @{ id = [string]$s.Identifier; name = [string]$s.Name; pct = $(if ($null -ne $s.Value) { [int][math]::Round([double]$s.Value) } else { $null }); sensor = $s } }
    return $o
}
function Fans-Temps {
    if ($script:MockMode) { return @{ cpu = 58; gpu = 62; board = 44; dbg = @('Temperature #1=44') } }
    $lh = Read-Lhm
    $cpu = $null; if ($lh.cpuTemps.Count) { $cpu = ($lh.cpuTemps.Values | Measure-Object -Maximum).Maximum }
    # датчик платы: сначала по имени; если плата отдаёт только безымянные «Temperature #N» (как у некоторых плат),
    # берём их, отбрасывая пустые входы (вне 10..100 °C). Берём максимум: при сомнении охлаждаем сильнее.
    $bd = $null
    $bt = @($lh.temps | Where-Object { $_.name -match 'Chipset|PCH|Motherboard|System|VRM' -and $_.c -gt 10 -and $_.c -lt 100 })
    $bdNamed = $null; if ($bt.Count) { $bdNamed = (@($bt | ForEach-Object { [double]$_.c }) | Measure-Object -Maximum).Maximum }
    if (-not $bt.Count) { $bt = @($lh.temps | Where-Object { $_.name -match '^Temperature #\d+$' -and $_.c -gt 10 -and $_.c -lt 100 }) }
    if ($bt.Count) { $bd = (@($bt | ForEach-Object { [double]$_.c }) | Measure-Object -Maximum).Maximum }
    $dbg = @($lh.temps | ForEach-Object { [string]$_.name + '=' + [string]$_.c }); if (-not $dbg.Count) { $dbg = @('нет датчиков температуры: lhm=' + [string]($null -ne $script:lhm)) }
    return @{ cpu = $cpu; gpu = $lh.gpuCore; board = $bd; boardCtl = $bdNamed; dbg = $dbg; boardCandidates = @($bt | ForEach-Object { [string]$_.name + '=' + [string]$_.c }) }
}
function Fans-Status {
    $cfg = Fans-Cfg; $t = Fans-Temps; $cs = @(Fans-Controls)
    $out = @()
    foreach ($c in $cs) {
        $f = @($cfg.fans | Where-Object { $_.id -eq $c.id }) | Select-Object -First 1
        $out += [ordered]@{ id = $c.id; name = $c.name; pct = $c.pct; sel = [bool]($f -and $f.sel); src = $(if ($f -and $f.src) { [string]$f.src } else { 'cpu' }); set = $script:FanLast[$c.id] }
    }
    $note = ''
    if (-not $script:MockMode) {
        if (-not $script:isAdmin) { $note = 'Нужны права администратора: запускайте через Start.bat.' }
        elseif (-not $cs.Count) { $note = 'Ваша материнская плата не отдаёт программе управление вентиляторами (так бывает на части плат и ноутбуков). Тогда используйте BIOS или программу производителя.' }
    }
    return [ordered]@{ controls = $out; enabled = $cfg.enabled; target = $cfg.target; temps = $t; floor = $script:FanFloor; admin = [bool]($script:isAdmin -or $script:MockMode); note = $note; releaseErr = @($script:ReleaseErr | Where-Object { $_ }) }
}
function Fans-Set($b) {
    $cfg = Fans-Cfg
    $t = [int]$b.target; if ($t -lt 50) { $t = 50 }; if ($t -gt 90) { $t = 90 }
    $valid = @(Fans-Controls | ForEach-Object { $_.id })
    $fans = @()
    foreach ($f in @($b.fans)) {
        $id = [string]$f.id; if ($valid -notcontains $id) { continue }
        $src = [string]$f.src; if (@('cpu', 'gpu', 'max') -notcontains $src) { $src = 'cpu' }
        $fans += [ordered]@{ id = $id; sel = [bool]$f.sel; src = $src }
    }
    $en = [bool]$b.enabled
    if ($en -and -not @($fans | Where-Object { $_.sel }).Count) { return [ordered]@{ ok = $false; message = 'Отметьте хотя бы один вентилятор.' } }
    if ($en -and -not $script:MockMode -and -not $script:isAdmin) { return [ordered]@{ ok = $false; message = 'Нужны права администратора (Start.bat).' } }
    $was = $cfg.enabled
    # сначала сохраняем выключение, чтобы фоновый тик перестал писать обороты; потом отдаём управление плате
    try { Fans-CfgSave ([ordered]@{ enabled = $en; target = $t; fans = $fans }) } catch { return [ordered]@{ ok = $false; message = 'Не удалось сохранить настройки: ' + $_.Exception.Message } }
    if (-not $en) { Fans-Release }
    if (-not $en -and @($script:ReleaseErr | Where-Object { $_ }).Count) { return [ordered]@{ ok = $false; message = 'Автоуправление выключено, но плата не подтвердила возврат управления: ' + (@($script:ReleaseErr | Where-Object { $_ }) -join '; ') + '. Вентиляторы могут оставаться на прежней скорости: перезагрузите ПК.' } }
    if ($en -and -not $was) { [void](Add-Event 'fan' 'Автоуправление вентиляторами включено' ('Цель: держать до ' + $t + ' °C. Нижний предел оборотов ' + $script:FanFloor + '%.')) }
    if (-not $en -and $was) { [void](Add-Event 'fan' 'Автоуправление вентиляторами выключено' 'Управление возвращено материнской плате.') }
    return [ordered]@{ ok = $true; message = $(if ($en) { 'Автоуправление включено.' } else { 'Автоуправление выключено, управление возвращено плате.' }) }
}
function Fans-Release {
    $script:FanLast = @{}
    $script:ReleaseErr = @()
    if ($script:MockMode) { $script:FanMock = @{}; return }
    foreach ($c in @(Fans-Controls)) { try { $c.sensor.Control.SetDefault() } catch { $script:ReleaseErr += ([string]$c.name + ': ' + $_.Exception.Message) } }
}
function Fan-Pct($temp, $target) {
    # тихо: ниже цели-25 °C минимум (35%); у цели около 70%; выше цели растёт до 100% на цели+10 °C
    $fl = $script:FanFloor
    $a = $target - 25
    if ($temp -le $a) { return $fl }
    if ($temp -lt $target) { return [int][math]::Round($fl + (($temp - $a) / 25.0) * (70 - $fl)) }
    if ($temp -ge $target + 10) { return 100 }
    return [int][math]::Round(70 + (($temp - $target) / 10.0) * 30)
}
function Fans-Tick {
    $cfg = Fans-Cfg
    if (-not $cfg.enabled) { return }
    $t = Fans-Temps
    $sel = @($cfg.fans | Where-Object { $_.sel })
    if (-not $sel.Count) { return }
    $cs = @(Fans-Controls)
    foreach ($f in $sel) {
        $c = @($cs | Where-Object { $_.id -eq $f.id }) | Select-Object -First 1
        if (-not $c) { continue }
        $vals = @(); if ($f.src -eq 'cpu') { $vals = @($t.cpu) } elseif ($f.src -eq 'gpu') { $vals = @($t.gpu) } else { $vals = @($t.cpu, $t.gpu, $t.boardCtl) }
        $vals = @($vals | Where-Object { $null -ne $_ })
        if (-not $vals.Count) {
            # датчик температуры пропал: после 3 промахов подряд отдаём управление плате
            $script:FanBad++
            if ($script:FanBad -ge 3) { try { if ($script:MockMode) { $script:FanMock.Remove($f.id) } else { $c.sensor.Control.SetDefault() } } catch { }; $script:FanLast.Remove($f.id) }
            continue
        }
        $script:FanBad = 0
        $want = Fan-Pct (($vals | Measure-Object -Maximum).Maximum) ([int]$cfg.target)
        $cur = $script:FanLast[$f.id]; if ($null -eq $cur) { $cur = $(if ($null -ne $c.pct) { [int]$c.pct } else { $want }) }
        # плавно: вниз не быстрее 4% за шаг, вверх сразу до 15%, при перегреве мгновенно
        $new = $want
        if ($want -gt $cur + 15 -and $want -lt 100) { $new = $cur + 15 } elseif ($want -lt $cur - 4) { $new = $cur - 4 }
        if ($new -lt $script:FanFloor) { $new = $script:FanFloor }; if ($new -gt 100) { $new = 100 }
        $script:FanLast[$f.id] = $new
        if ($script:MockMode) { $script:FanMock[$f.id] = $new } else { try { $c.sensor.Control.SetSoftware([single]$new) } catch { } }
    }
}
