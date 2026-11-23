# PC Doctor: действия. Каждое действие из белого списка, с подтверждением на странице, записью в журнал и откатом там, где это возможно.
$script:AppDir = $null
$script:MockMode = $false
$script:HighPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:Ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

function Json-Read($path, $default) {
    try {
        if (Test-Path -LiteralPath $path) {
            $t = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if ($t.Trim()) {
                try { return ($t | ConvertFrom-Json) }
                catch { try { Move-Item -LiteralPath $path -Destination ($path + '.bad') -Force } catch { } }   # битый файл не затираем молча
            }
        }
    } catch { }
    return $default
}
function Json-Write($path, $obj) {
    $j = ConvertTo-Json -InputObject $obj -Depth 8
    # атомарная запись: сначала во временный файл, потом замена (обрыв питания не оставит обрезанный журнал)
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, $j, (New-Object Text.UTF8Encoding($false)))
    try {
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, $null) } else { [IO.File]::Move($tmp, $path) }
    } catch {
        [IO.File]::WriteAllText($path, $j, (New-Object Text.UTF8Encoding($false)))
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    }
}
function Journal-Path { Join-Path $script:AppDir 'journal.json' }
function History-Path { Join-Path $script:AppDir 'history.json' }
function Events-Path { Join-Path $script:AppDir 'events.json' }
function Add-Event($kind, $title, $detail) {
    if (-not $title) { return [ordered]@{ ok = $false } }
    $k = ([string]$kind) -replace '[^a-z0-9._-]', ''
    if ($k.Length -gt 24) { $k = $k.Substring(0, 24) }
    $t = [string]$title; if ($t.Length -gt 140) { $t = $t.Substring(0, 140) }
    $d = [string]$detail; if ($d.Length -gt 300) { $d = $d.Substring(0, 300) }
    $all = @(Json-Read (Events-Path) @())
    # одинаковое событие не пишем чаще раза в 30 минут (раньше «диск заполнен» повторялся каждые 15 секунд)
    $lastSame = $all | Where-Object { $_.kind -eq $k -and $_.title -eq $t } | Select-Object -Last 1
    if ($lastSame) { try { if (((Get-Date) - [datetime]$lastSame.time).TotalMinutes -lt 30) { return [ordered]@{ ok = $true; dup = $true } } } catch { } }
    $all += [ordered]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); kind = $k; title = $t; detail = $d }
    if ($all.Count -gt 200) { $all = @($all | Select-Object -Last 200) }
    Json-Write (Events-Path) $all
    return [ordered]@{ ok = $true }
}
function Journal-Get { @(Json-Read (Journal-Path) @()) }
function Journal-Add($entry) {
    $all = @(Journal-Get); $all += $entry
    if ($all.Count -gt 200) { $all = $all[($all.Count - 200)..($all.Count - 1)] }
    Json-Write (Journal-Path) $all
}

function Test-Admin {
    try { $id = [Security.Principal.WindowsIdentity]::GetCurrent(); return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

# ---------- белый список кэшей (дублирует scan.ps1; путь проверяется на сервере, не берётся от страницы) ----------
function Get-KnownCaches {
    $L = $env:LOCALAPPDATA
    @(
        @{ id = 'nv-dx'; name = 'Кэш шейдеров NVIDIA'; path = "$L\NVIDIA\DXCache" },
        @{ id = 'nv-gl'; name = 'Кэш OpenGL NVIDIA'; path = "$L\NVIDIA\GLCache" },
        @{ id = 'temp'; name = 'Временные файлы пользователя'; path = $env:TEMP },
        @{ id = 'capcut'; name = 'Кэш CapCut'; path = "$L\CapCut\User Data\Cache" },
        @{ id = 'insta'; name = 'Логи Insta360 Link Controller'; path = "$L\Insta360 Link Controller\log" },
        @{ id = 'chrome'; name = 'Кэш Chrome'; path = "$L\Google\Chrome\User Data\Default\Cache" },
        @{ id = 'edge'; name = 'Кэш Edge'; path = "$L\Microsoft\Edge\User Data\Default\Cache" },
        @{ id = 'uv'; name = 'Кэш uv (Python)'; path = "$L\uv\cache" },
        @{ id = 'pip'; name = 'Кэш pip'; path = "$L\pip\Cache" }
    )
}

function Clean-Dir($d) {
    # обход без захода в junction и символьные ссылки: иначе можно удалить чужие файлы за пределами кэша
    foreach ($e in @($d.GetFileSystemInfos())) {
        if ($script:cleanDeadline -and [DateTime]::UtcNow -gt $script:cleanDeadline) { $script:cleanCut = $true; return }
        try {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e -is [IO.DirectoryInfo]) {
                Clean-Dir $e
                if (-not $script:cleanCut -and @($e.GetFileSystemInfos()).Count -eq 0) { $e.Delete() }
            } else {
                $len = $e.Length; $e.Attributes = [IO.FileAttributes]::Normal; $e.Delete(); $script:cleanB += $len; $script:cleanF++
            }
        } catch { }
    }
}
function Action-Clean($ids) {
    # step: 0 - всё сразу; 1 - первая порция; 2 - следующая. Порция ограничена по времени, чтобы программа оставалась отзывчивой.
    $step = [int]$script:CleanStep
    if ($step -le 1) { $script:accB = 0L; $script:accF = 0 }
    $freed = 0L; $files = 0; $per = @(); $cut = $false
    foreach ($c in (Get-KnownCaches)) {
        if ($ids -and ($ids -notcontains $c.id)) { continue }
        $p = $c.path
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $full = [IO.Path]::GetFullPath($p)
        # защита: только внутри профиля пользователя, не корень и не короткий путь
        if ($full.Length -lt 20 -or -not ($full.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase))) { continue }
        $script:cleanB = 0L; $script:cleanF = 0; $script:cleanCut = $false
        $script:cleanDeadline = $(if ($step -gt 0) { [DateTime]::UtcNow.AddMilliseconds(1200) } else { $null })
        Clean-Dir (New-Object IO.DirectoryInfo($full))
        $script:cleanDeadline = $null
        $b = $script:cleanB; $files += $script:cleanF
        $freed += $b; $per += [ordered]@{ name = $c.name; bytes = $b }
        if ($script:cleanCut) { $cut = $true; break }
    }
    $script:accB += $freed; $script:accF += $files
    return [ordered]@{ ok = $true; done = (-not $cut); freedBytes = $freed; totalBytes = $script:accB; files = $files; totalFiles = $script:accF; per = $per
        message = ('Освобождено {0} ГБ, удалено файлов: {1}. Файлы, занятые Windows или программами, пропущены.' -f ([math]::Round($script:accB / 1GB, 2)), $script:accF) }
}

function Get-ActiveScheme {
    $t = (powercfg /getactivescheme) -join ' '
    if ($t -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLower() }
    return $null
}
function Get-UsbSuspendValue {
    $t = @(powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226)
    $hex = @($t | Where-Object { $_ -match '0x[0-9a-fA-F]{8}' } | ForEach-Object { [Convert]::ToInt32(([regex]::Match($_, '0x([0-9a-fA-F]{8})')).Groups[1].Value, 16) })
    if ($hex.Count -ge 2) { return $hex[$hex.Count - 2] }
    return $null
}
function Get-NicPower {
    @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|TAP-|Wintun|Hyper-V|Bluetooth|Loopback|VPN|WAN Miniport|vEthernet|VMware|VirtualBox|Npcap' } | ForEach-Object {
        $pm = $null; try { $pm = (Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction Stop).AllowComputerToTurnOffDevice } catch { }
        [ordered]@{ name = $_.Name; desc = $_.InterfaceDescription; state = [string]$pm }
    })
}

function Make-RestorePoint {
    if (-not (Test-Admin)) { return $false }
    try { Checkpoint-Computer -Description 'PC Doctor' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; return $true } catch { return $false }
}

# ---- реестр (только ветка текущего пользователя) для игровых настроек ----

$script:RegMouse = 'HKCU:\Control Panel\Mouse'

$script:RegDvr1 = 'HKCU:\System\GameConfigStore'

$script:RegDvr2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'

$script:RegGb = 'HKCU:\Software\Microsoft\GameBar'

function Reg-Get($path, $name) { try { return (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name } catch { return $null } }

function Reg-Put($path, $name, $value, $type) {

    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }

    if ($null -eq $value) { Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue }

    else { Set-ItemProperty -LiteralPath $path -Name $name -Value $value -Type $type -Force }

}

function Apply-MouseAccel($speed, $t1, $t2) {

    # сразу применяем настройку мыши без перезагрузки

    try {

        if (-not ('PCD.Native' -as [type])) { Add-Type -Namespace PCD -Name Native -MemberDefinition '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(int a, int b, int[] c, int d);' }

        [void][PCD.Native]::SystemParametersInfo(4, 0, [int[]]@([int]$t1, [int]$t2, [int]$speed), 3)

    } catch { }

}

function Get-MouseAccelOn { $v = Reg-Get $script:RegMouse 'MouseSpeed'; return ([string]$v -ne '0') }

function Get-GameDvrOn { $a = Reg-Get $script:RegDvr1 'GameDVR_Enabled'; $b = Reg-Get $script:RegDvr2 'AppCaptureEnabled'; return (($null -eq $a -or $a -ne 0) -or ($null -eq $b -or $b -ne 0)) }

function Get-GameModeState { $v = Reg-Get $script:RegGb 'AutoGameModeEnabled'; if ($null -eq $v) { return 'default' }; if ($v -eq 1) { return 'on' }; return 'off' }
$script:RegSticky = 'HKCU:\Control Panel\Accessibility\StickyKeys'
$script:RegFilter = 'HKCU:\Control Panel\Accessibility\Keyboard Response'
function Get-StickyHotkeyOn { foreach ($p in @(@($script:RegSticky,'Flags'), @($script:RegFilter,'Flags'))) { $v = Reg-Get $p[0] $p[1]; if ($null -ne $v -and (([int]$v) -band 4)) { return $true } }; return $false }
function Get-MouseSensValue { $v = Reg-Get $script:RegMouse 'MouseSensitivity'; if ($null -eq $v) { return 10 }; return [int]$v }
function Apply-MouseSens($n) { try { if (-not ('PCD.Native2' -as [type])) { Add-Type -Namespace PCD -Name Native2 -MemberDefinition '[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(int a, int b, IntPtr c, int d);' }; [void][PCD.Native2]::SystemParametersInfo(113, 0, [IntPtr][int]$n, 3) } catch { } }
function Get-PadGameBarOn { $v = Reg-Get $script:RegGb 'UseNexusForGameBarEnabled'; return ($null -eq $v -or $v -ne 0) }
function Get-PcieAspmValue {
    $t = @(powercfg /query SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5)
    $hex = @($t | Where-Object { $_ -match '0x[0-9a-fA-F]{8}' } | ForEach-Object { [Convert]::ToInt32(([regex]::Match($_, '0x([0-9a-fA-F]{8})')).Groups[1].Value, 16) })
    if ($hex.Count -ge 2) { return $hex[$hex.Count - 2] }
    return $null
}



function Get-ActionList($isLaptop) {
    if ($script:MockMode) {
        $mj = @(Journal-Get)
        $mst = { param($i) if (@($mj | Where-Object { $_.action -eq $i -and $_.undoable -and -not $_.undone }).Count -gt 0) { 'done' } else { 'ready' } }
        return @(
            [ordered]@{ id = 'clean-caches'; title = 'Очистить безопасные кэши'; what = 'Удаляет файлы только из проверенного списка.'; undoable = $false; admin = $false; state = 'ready'; detail = 'тест' },
            [ordered]@{ id = 'power-high'; title = 'План питания «Высокая производительность»'; what = 'Переключает схему питания.'; undoable = $true; admin = $false; state = (& $mst 'power-high'); detail = 'тест' },
            [ordered]@{ id = 'usb-suspend'; title = 'Запретить отключение USB-портов'; what = 'Не даёт Windows отключать USB-порты для экономии энергии.'; undoable = $true; admin = $false; state = (& $mst 'usb-suspend'); detail = 'тест' },
            [ordered]@{ id = 'nic-power'; title = 'Запретить выключать сетевой адаптер'; what = 'Нужны права администратора.'; undoable = $true; admin = $true; state = (& $mst 'nic-power'); detail = 'тест' },
            [ordered]@{ id = 'mouse-accel'; title = 'Выключить ускорение мыши'; what = 'Прицел двигается строго по руке.'; undoable = $true; admin = $false; state = (& $mst 'mouse-accel'); detail = 'тест' },
            [ordered]@{ id = 'gamedvr'; title = 'Выключить фоновую запись игр (Xbox Game Bar)'; what = 'Снимает фоновую нагрузку.'; undoable = $true; admin = $false; state = (& $mst 'gamedvr'); detail = 'тест' },
            [ordered]@{ id = 'gamemode'; title = 'Включить игровой режим Windows'; what = 'Система не мешает игре фоновыми задачами.'; undoable = $true; admin = $false; state = (& $mst 'gamemode'); detail = 'тест' },
            [ordered]@{ id = 'sticky-keys'; title = 'Отключить окна залипания клавиш'; what = 'Shift ×5 больше не сворачивает игру.'; undoable = $true; admin = $false; state = (& $mst 'sticky-keys'); detail = 'тест' },
            [ordered]@{ id = 'mouse-speed'; title = 'Скорость указателя 6/11'; what = 'Честное 1:1.'; undoable = $true; admin = $false; state = (& $mst 'mouse-speed'); detail = 'тест' },
            [ordered]@{ id = 'gamebar-pad'; title = 'Геймпад не открывает Game Bar'; what = 'Кнопка Xbox не вызывает оверлей.'; undoable = $true; admin = $false; state = (& $mst 'gamebar-pad'); detail = 'тест' },
            [ordered]@{ id = 'pcie-aspm'; title = 'Не усыплять линию PCIe видеокарты'; what = 'Меньше микрофризов.'; undoable = $true; admin = $false; state = (& $mst 'pcie-aspm'); detail = 'тест' })
    }
    $mjr = @(Journal-Get)
    $usOn = { param($i) @($mjr | Where-Object { $_.action -eq $i -and $_.undoable -and -not $_.undone }).Count -gt 0 }
    $adm = Test-Admin
    $cur = Get-ActiveScheme
    $isHigh = ($cur -eq $script:HighPerf -or $cur -eq $script:Ultimate)
    $usbv = Get-UsbSuspendValue
    $pcie = Get-PcieAspmValue
    $nics = @(Get-NicPower)
    $nicOn = @($nics | Where-Object { $_.state -match 'Enabled|True' })
    $caches = @(Get-KnownCaches | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) })
    $list = @(
        [ordered]@{ id = 'clean-caches'; title = 'Очистить безопасные кэши'; what = 'Удаляет файлы только из проверенного списка: кэш шейдеров NVIDIA, временные файлы пользователя, кэш браузеров, кэш pip и uv. Проекты, документы и файлы игр не затрагиваются. Программы пересоздадут кэш сами.'
            undoable = $false; admin = $false; state = 'ready'; detail = ('Папок в списке: ' + $caches.Count) },
        [ordered]@{ id = 'power-high'; title = 'План питания «Высокая производительность»'; what = 'Переключает схему питания Windows на «Высокая производительность», чтобы процессор не снижал частоту в играх. Можно вернуть прежнюю схему.'
            undoable = $true; admin = $false; state = $(if ($isHigh) { 'done' } elseif ($isLaptop) { 'skip' } else { 'ready' }); detail = ('Сейчас: ' + $(if ($cur -eq $script:Ultimate) { 'максимальная производительность' } elseif ($cur -eq $script:HighPerf) { 'высокая производительность' } else { $nm = ''; try { $o = (powercfg /getactivescheme 2>$null | Out-String); if ($o -match '\(([^)]+)\)') { $nm = $Matches[1] } } catch {}; if ($nm) { $nm } else { 'другая схема' } })) },
        [ordered]@{ id = 'usb-suspend'; title = 'Запретить отключение USB-портов для экономии энергии'; what = 'В текущей схеме питания отключает «временное отключение USB-порта». Помогает USB Wi‑Fi адаптерам, гарнитурам и мышам не пропадать. Можно вернуть прежнее значение.'
            undoable = $true; admin = $false; state = $(if ($usbv -eq 0) { 'done' } else { 'ready' }); detail = ('Сейчас значение: ' + $usbv) },
        [ordered]@{ id = 'nic-power'; title = 'Запретить Windows выключать сетевой адаптер для экономии энергии'; what = 'Для активных сетевых адаптеров снимает разрешение на отключение ради экономии энергии. Нужны права администратора. Можно вернуть.'
            undoable = $true; admin = $true; state = $(if (-not $adm) { 'needadmin' } elseif ($nicOn.Count -gt 0) { 'ready' } elseif ($nics.Count -gt 0) { 'done' } else { 'skip' }); detail = ('Адаптеров: ' + $nics.Count + ', с включённым энергосбережением: ' + $nicOn.Count) },
        [ordered]@{ id = 'mouse-accel'; title = 'Выключить ускорение мыши («Повышенная точность указателя»)'; what = 'Windows по умолчанию ускоряет курсор при быстром движении руки, из-за чего прицел ведёт себя непредсказуемо. Выключение делает отклик строго пропорциональным движению. Для шутеров это важно. FPS не меняется.'
            undoable = $true; admin = $false; state = $(if (Get-MouseAccelOn) { 'ready' } else { 'done' }); detail = ('Сейчас: ' + $(if (Get-MouseAccelOn) { 'ускорение включено' } else { 'ускорение выключено' })) },
        [ordered]@{ id = 'gamedvr'; title = 'Выключить фоновую запись игр (Xbox Game Bar)'; what = 'Windows может в фоне записывать геймплей и держать для этого ресурсы. Если вы не пользуетесь записью через Win+G, её можно отключить: меньше фоновой нагрузки и возможных микрофризов.'
            undoable = $true; admin = $false; state = $(if (Get-GameDvrOn) { 'ready' } else { 'done' }); detail = ('Сейчас: ' + $(if (Get-GameDvrOn) { 'запись разрешена' } else { 'запись выключена' })) },
        [ordered]@{ id = 'gamemode'; title = 'Включить игровой режим Windows'; what = 'Во время игры Windows не запускает установку драйверов и обновлений и отдаёт приоритет игре. Эффект небольшой, но бесплатный.'
            undoable = $true; admin = $false; state = $(if ((Get-GameModeState) -eq 'off') { 'ready' } elseif (& $usOn 'gamemode') { 'done' } else { 'skip' }); detail = ('Сейчас: ' + $(switch (Get-GameModeState) { 'on' { 'включён' } 'off' { 'выключен' } default { 'включён по умолчанию' } })) },
        [ordered]@{ id = 'sticky-keys'; title = 'Отключить всплывающие окна залипания клавиш'; what = 'Если в игре пять раз нажать Shift (или удерживать правый Shift), Windows показывает окно и сворачивает игру. Выключаем только горячую клавишу, сами функции доступности остаются в Параметрах. Изменение применяется при следующем входе в Windows.'; undoable = $true; admin = $false; state = $(if (Get-StickyHotkeyOn) { 'ready' } else { 'done' }); detail = ('Сейчас: ' + $(if (Get-StickyHotkeyOn) { 'окно появляется' } else { 'окно отключено' })) },
        [ordered]@{ id = 'mouse-speed'; title = 'Скорость указателя 6/11 (честное 1:1)'; what = 'Это стандартная скорость Windows: курсор и прицел двигаются ровно на столько, на сколько вы сдвинули мышь. Любое другое значение пропускает или удваивает пиксели. Чувствительность подбирайте в самой игре и через DPI мыши.'; undoable = $true; admin = $false; state = $(if ((Get-MouseSensValue) -eq 10) { 'done' } else { 'ready' }); detail = ('Сейчас: ' + (Get-MouseSensValue) + ' из 20 (нужно 10)') },
        [ordered]@{ id = 'gamebar-pad'; title = 'Кнопка геймпада не открывает Game Bar'; what = 'По умолчанию кнопка Xbox на геймпаде вызывает оверлей Game Bar поверх игры. Если играете на геймпаде, это может случайно свернуть или перебить игру.'; undoable = $true; admin = $false; state = $(if (Get-PadGameBarOn) { 'ready' } else { 'done' }); detail = ('Сейчас: ' + $(if (Get-PadGameBarOn) { 'открывает Game Bar' } else { 'не открывает' })) },
        [ordered]@{ id = 'pcie-aspm'; title = 'Не усыплять линию PCIe видеокарты'; what = 'Windows может переводить шину PCIe в энергосберегающий режим и «будить» её при нагрузке: из-за этого бывают редкие микрофризы. Отключаем экономию в текущей схеме питания. Видеокарта будет потреблять в простое чуть больше.'; undoable = $true; admin = $false; state = $(if ($isLaptop) { 'skip' } elseif ($null -eq $pcie) { 'skip' } elseif ($pcie -eq 0) { 'done' } else { 'ready' }); detail = ('Сейчас: ' + $(switch ($pcie) { 0 { 'экономия выключена' } 1 { 'умеренная экономия' } 2 { 'максимальная экономия' } default { 'параметр недоступен' } })) }
    )
    foreach ($x in $list) { $x.byUs = [bool](& $usOn $x.id) }
    return $list
}

function Run-Action($id, $ids, $isLaptop) {
    $when = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if ($id -ne 'clean-caches') {
        # повторное применение затёрло бы исходное значение для отката: второй раз не применяем
        $act = @(Journal-Get) | Where-Object { $_.action -eq $id -and $_.undoable -and -not $_.undone } | Select-Object -First 1
        if ($act) { return [ordered]@{ ok = $false; already = $true; message = 'Это уже применено. Чтобы применить заново, сначала откатите прежнюю запись на странице «Отчёты».' } }
    }
    if ($script:MockMode) {
        Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = ('Тест: ' + $id); undoable = ($id -ne 'clean-caches'); undone = $false; result = 'тест' })
        return [ordered]@{ ok = $true; message = 'Готово (тестовый режим, ничего не изменено).'; freedBytes = 3500000000 }
    }
    switch ($id) {
        'clean-caches' {
            $r = Action-Clean $ids
            if ($r.done) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = $(if (@($r.per).Count -eq 1) { 'Очистка кэша: ' + $r.per[0].name } else { 'Очистка безопасных кэшей' }); undoable = $false; undone = $false; result = $r.message; freedBytes = $r.totalBytes }) }
            return $r
        }
        'power-high' {
            $before = Get-ActiveScheme
            $rp = Make-RestorePoint
            powercfg /setactive $script:HighPerf | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $o = (powercfg -duplicatescheme $script:HighPerf) -join ' '
                if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { powercfg /setactive $Matches[1] | Out-Null }
            }
            $after = Get-ActiveScheme
            $ok = ($after -ne $before)
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'План питания: высокая производительность'; undoable = $true; undone = $false; before = $before; restorePoint = $rp; result = 'Схема питания переключена.' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: включена высокая производительность.' + $(if ($rp) { ' Точка восстановления создана.' } else { '' }) } else { 'Windows не дал переключить схему питания.' }) }
        }
        'usb-suspend' {
            $before = Get-UsbSuspendValue
            $rp = Make-RestorePoint
            powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
            powercfg /setactive SCHEME_CURRENT | Out-Null
            $after = Get-UsbSuspendValue
            $ok = ($after -eq 0)
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'USB: отключение портов запрещено'; undoable = $true; undone = $false; before = $before; restorePoint = $rp; result = 'Параметр применён.' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: USB-порты больше не отключаются для экономии энергии.' } else { 'Не удалось изменить параметр питания USB.' }) }
        }
        'mouse-accel' {
            $b = [ordered]@{ speed = (Reg-Get $script:RegMouse 'MouseSpeed'); t1 = (Reg-Get $script:RegMouse 'MouseThreshold1'); t2 = (Reg-Get $script:RegMouse 'MouseThreshold2') }
            Reg-Put $script:RegMouse 'MouseSpeed' '0' String; Reg-Put $script:RegMouse 'MouseThreshold1' '0' String; Reg-Put $script:RegMouse 'MouseThreshold2' '0' String
            Apply-MouseAccel 0 0 0
            $ok = (-not (Get-MouseAccelOn))
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Мышь: ускорение выключено'; undoable = $true; undone = $false; before = $b; result = 'ускорение выключено' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: ускорение мыши выключено. Работает сразу, перезагрузка не нужна.' } else { 'Не удалось изменить настройку мыши.' }) }
        }
        'gamedvr' {
            $b = [ordered]@{ a = (Reg-Get $script:RegDvr1 'GameDVR_Enabled'); b = (Reg-Get $script:RegDvr2 'AppCaptureEnabled') }
            Reg-Put $script:RegDvr1 'GameDVR_Enabled' 0 DWord; Reg-Put $script:RegDvr2 'AppCaptureEnabled' 0 DWord
            $ok = (-not (Get-GameDvrOn))
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Фоновая запись игр выключена'; undoable = $true; undone = $false; before = $b; result = 'запись выключена' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: фоновая запись игр выключена. Полностью вступит в силу после перезапуска игры.' } else { 'Не удалось изменить настройку.' }) }
        }
        'sticky-keys' {
            $b = [ordered]@{ s = (Reg-Get $script:RegSticky 'Flags'); f = (Reg-Get $script:RegFilter 'Flags') }
            if ($null -ne $b.s) { Reg-Put $script:RegSticky 'Flags' ([string](([int]$b.s) -band (-bnot 4))) String }
            if ($null -ne $b.f) { Reg-Put $script:RegFilter 'Flags' ([string](([int]$b.f) -band (-bnot 4))) String }
            $ok = (-not (Get-StickyHotkeyOn))
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Залипание клавиш: окна отключены'; undoable = $true; undone = $false; before = $b; result = 'окна отключены' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: Shift ×5 больше не вызывает окно залипания. Полностью вступит в силу после следующего входа в Windows.' } else { 'Не удалось изменить настройку.' }) }
        }
        'mouse-speed' {
            $b = [ordered]@{ v = (Reg-Get $script:RegMouse 'MouseSensitivity') }
            Reg-Put $script:RegMouse 'MouseSensitivity' '10' String
            Apply-MouseSens 10
            $ok = ((Get-MouseSensValue) -eq 10)
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Мышь: скорость указателя 6/11'; undoable = $true; undone = $false; before = $b; result = 'скорость 10 из 20' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: скорость указателя 6/11. Работает сразу.' } else { 'Не удалось изменить скорость указателя.' }) }
        }
        'gamebar-pad' {
            $b = [ordered]@{ v = (Reg-Get $script:RegGb 'UseNexusForGameBarEnabled') }
            Reg-Put $script:RegGb 'UseNexusForGameBarEnabled' 0 DWord
            $ok = (-not (Get-PadGameBarOn))
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Геймпад: Game Bar не открывается'; undoable = $true; undone = $false; before = $b; result = 'отключено' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: кнопка геймпада больше не открывает Game Bar.' } else { 'Не удалось изменить настройку.' }) }
        }
        'pcie-aspm' {
            $before = Get-PcieAspmValue
            powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
            powercfg /setactive SCHEME_CURRENT | Out-Null
            $ok = ((Get-PcieAspmValue) -eq 0)
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'PCIe: экономия энергии выключена'; undoable = $true; undone = $false; before = $before; result = 'параметр применён' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: PCIe больше не уходит в энергосбережение.' } else { 'Не удалось изменить параметр питания PCIe.' }) }
        }
        'gamemode' {
            $b = [ordered]@{ v = (Reg-Get $script:RegGb 'AutoGameModeEnabled') }
            Reg-Put $script:RegGb 'AutoGameModeEnabled' 1 DWord
            $ok = ((Get-GameModeState) -eq 'on')
            if ($ok) { Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = 'Игровой режим Windows включён'; undoable = $true; undone = $false; before = $b; result = 'включён' }) }
            return [ordered]@{ ok = $ok; message = $(if ($ok) { 'Готово: игровой режим Windows включён.' } else { 'Не удалось изменить настройку.' }) }
        }
        'nic-power' {
            if (-not (Test-Admin)) { return [ordered]@{ ok = $false; message = 'Нужны права администратора. Закройте программу и запустите Admin.bat.' } }
            $rp = Make-RestorePoint
            $changed = @()
            foreach ($n in (Get-NicPower)) {
                if ($n.state -match 'Enabled|True') {
                    try { Set-NetAdapterPowerManagement -Name $n.name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop; $changed += [ordered]@{ name = $n.name; before = 'Enabled' } } catch { }
                }
            }
            if ($changed.Count -gt 0) {
                Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = $when; action = $id; title = ('Энергосбережение адаптера отключено: ' + (($changed | ForEach-Object { $_.name }) -join ', ')); undoable = $true; undone = $false; adapters = $changed; restorePoint = $rp; result = 'Параметр применён.' })
                return [ordered]@{ ok = $true; message = 'Готово: энергосбережение отключено для адаптеров: ' + (($changed | ForEach-Object { $_.name }) -join ', ') + '.' }
            }
            return [ordered]@{ ok = $false; message = 'Windows не позволил изменить это для вашего адаптера (так бывает у USB-адаптеров). Сделайте вручную: Диспетчер устройств → адаптер → Электропитание.' }
        }
        default { return [ordered]@{ ok = $false; message = 'Неизвестное действие.' } }
    }
}

function Run-Undo($entryId) {
    if ($script:MockMode) { $all = @(Journal-Get); foreach ($x in $all) { if ($x.id -eq $entryId) { $x.undone = $true } }; Json-Write (Journal-Path) $all; return [ordered]@{ ok = $true; message = 'Откат выполнен (тест).' } }
    $all = @(Journal-Get)
    $e = $all | Where-Object { $_.id -eq $entryId } | Select-Object -First 1
    if (-not $e) { return [ordered]@{ ok = $false; message = 'Запись не найдена.' } }
    if (-not $e.undoable -or $e.undone) { return [ordered]@{ ok = $false; message = 'Эту запись нельзя откатить.' } }
    $ok = $false; $msg = ''
    switch ($e.action) {
        'trash-files' {
            $rr = Restore-FromBin @($e.files)
            if ($rr.restored -gt 0) { $ok = $true; $msg = ('Из Корзины возвращено файлов: ' + $rr.restored + ' из ' + $rr.total + '.' + $(if ($rr.restored -lt $rr.total) { ' Остальных в Корзине уже нет (её очистили).' } else { '' })) }
            else { $msg = 'Эти файлы в Корзине не найдены: возможно, её уже очистили.' }
        }
        'power-high' { if ($e.before) { powercfg /setactive $e.before | Out-Null; $ok = ((Get-ActiveScheme) -eq $e.before); $msg = 'Схема питания возвращена.' } }
        'usb-suspend' { if ($null -ne $e.before) { powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 ([int]$e.before) | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null; $ok = ((Get-UsbSuspendValue) -eq [int]$e.before); $msg = 'Параметр USB возвращён.' } }
        'mouse-accel' {
            if ($e.before) {
                Reg-Put $script:RegMouse 'MouseSpeed' $(if ($null -ne $e.before.speed) { [string]$e.before.speed } else { '1' }) String
                Reg-Put $script:RegMouse 'MouseThreshold1' $(if ($null -ne $e.before.t1) { [string]$e.before.t1 } else { '6' }) String
                Reg-Put $script:RegMouse 'MouseThreshold2' $(if ($null -ne $e.before.t2) { [string]$e.before.t2 } else { '10' }) String
                Apply-MouseAccel ([int]$(if ($null -ne $e.before.speed) { $e.before.speed } else { 1 })) ([int]$(if ($null -ne $e.before.t1) { $e.before.t1 } else { 6 })) ([int]$(if ($null -ne $e.before.t2) { $e.before.t2 } else { 10 }))
                $ok = (Get-MouseAccelOn); $msg = 'Ускорение мыши возвращено как было.'
            }
        }
        'gamedvr' {
            if ($e.before) { Reg-Put $script:RegDvr1 'GameDVR_Enabled' $e.before.a DWord; Reg-Put $script:RegDvr2 'AppCaptureEnabled' $e.before.b DWord; $ok = $true; $msg = 'Фоновая запись игр возвращена как была.' }
        }
        'sticky-keys' {
            if ($e.before) { Reg-Put $script:RegSticky 'Flags' $e.before.s String; Reg-Put $script:RegFilter 'Flags' $e.before.f String; $ok = $true; $msg = 'Окна залипания клавиш возвращены как были.' }
        }
        'mouse-speed' {
            if ($e.before) { Reg-Put $script:RegMouse 'MouseSensitivity' $(if ($null -ne $e.before.v) { [string]$e.before.v } else { '10' }) String; Apply-MouseSens ([int]$(if ($null -ne $e.before.v) { $e.before.v } else { 10 })); $ok = $true; $msg = 'Скорость указателя возвращена как была.' }
        }
        'gamebar-pad' {
            if ($e.before) { Reg-Put $script:RegGb 'UseNexusForGameBarEnabled' $e.before.v DWord; $ok = $true; $msg = 'Кнопка геймпада возвращена как была.' }
        }
        'pcie-aspm' { if ($null -ne $e.before) { powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 ([int]$e.before) | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null; $ok = ((Get-PcieAspmValue) -eq [int]$e.before); $msg = 'Параметр PCIe возвращён.' } }
        'gamemode' {
            if ($e.before) { Reg-Put $script:RegGb 'AutoGameModeEnabled' $e.before.v DWord; $ok = $true; $msg = 'Игровой режим Windows возвращён как был.' }
        }
        'nic-power' {
            if (-not (Test-Admin)) { return [ordered]@{ ok = $false; message = 'Для отката нужны права администратора (Admin.bat).' } }
            $ok = $true
            foreach ($a in @($e.adapters)) { try { Set-NetAdapterPowerManagement -Name $a.name -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop } catch { $ok = $false } }
            $msg = 'Энергосбережение адаптера возвращено.'
        }
    }
    if ($ok) {
        foreach ($x in $all) { if ($x.id -eq $entryId) { $x.undone = $true } }
        Json-Write (Journal-Path) $all
    }
    return [ordered]@{ ok = $ok; message = $(if ($ok) { $msg } elseif ($msg) { $msg } else { 'Не удалось откатить. Попробуйте вручную.' }) }
}

$script:ProtectedProcs = @('explorer', 'dwm', 'csrss', 'winlogon', 'svchost', 'system', 'idle', 'lsass', 'services', 'smss', 'wininit', 'powershell', 'pwsh', 'cmd', 'conhost', 'msmpeng',
    'easyanticheat', 'easyanticheat_eos', 'beservice', 'battleye', 'vgc', 'vgtray', 'nvcontainer', 'nvdisplay.container', 'searchhost', 'startmenuexperiencehost', 'shellexperiencehost', 'textinputhost', 'applicationframehost')
function Get-AppList {
    if ($script:MockMode) { return @([ordered]@{ id = 111; name = 'chrome'; title = 'YouTube - Google Chrome'; memMB = 1450 }, [ordered]@{ id = 222; name = 'Telegram'; title = 'Telegram'; memMB = 320 }, [ordered]@{ id = 333; name = 'Discord'; title = 'Discord'; memMB = 540 }) }
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and ($script:ProtectedProcs -notcontains $_.ProcessName.ToLower()) } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 14 | ForEach-Object {
            [ordered]@{ id = $_.Id; name = $_.ProcessName; title = $_.MainWindowTitle; memMB = [int]($_.WorkingSet64 / 1MB) } })
}
function Close-App($procId) {
    if ($script:MockMode) { return [ordered]@{ ok = $true; message = 'Закрыто (тест).' } }
    $p = Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue
    if (-not $p) { return [ordered]@{ ok = $false; message = 'Программа уже закрыта.' } }
    if ($script:ProtectedProcs -contains $p.ProcessName.ToLower()) { return [ordered]@{ ok = $false; message = 'Эту программу закрывать нельзя.' } }
    $mem = [int]($p.WorkingSet64 / 1MB)
    [void]$p.CloseMainWindow()
    Start-Sleep -Milliseconds 1200
    $p.Refresh()
    if ($p.HasExited) {
        Journal-Add ([ordered]@{ id = [guid]::NewGuid().ToString(); time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); action = 'close-app'; title = ('Закрыта программа: ' + $p.ProcessName); undoable = $false; undone = $false; result = ('Освобождено около ' + $mem + ' МБ памяти.') })
        return [ordered]@{ ok = $true; message = ('Закрыто: ' + $p.ProcessName + ', освобождено около ' + $mem + ' МБ.') }
    }
    return [ordered]@{ ok = $false; message = 'Программа не закрылась (возможно, спрашивает о сохранении). Закройте её сами.' }
}

function Open-Tool($what, $arg) {
    if ($script:MockMode) { return $true }
    $map = @{ devmgmt = 'devmgmt.msc'; network = 'ms-settings:network'; wifi = 'ms-settings:network-wifi'; ncpa = 'ncpa.cpl'; power = 'powercfg.cpl'; startup = 'taskmgr'
              apps = 'ms-settings:appsfeatures'; update = 'ms-settings:windowsupdate'; optupd = 'ms-settings:windowsupdate-optionalupdates'
              display = 'ms-settings:display'; sound = 'ms-settings:sound'; bluetooth = 'ms-settings:bluetooth'; themes = 'ms-settings:themes'; personal = 'ms-settings:personalization'
              storage = 'ms-settings:storagesense'; recovery = 'ms-settings:recovery'; about = 'ms-settings:about'; gamemode = 'ms-settings:gaming-gamemode'; gamebar = 'ms-settings:gaming-gamebar'; keyacc = 'ms-settings:easeofaccess-keyboard'; gfxpref = 'ms-settings:display-advancedgraphics'; mouse = 'ms-settings:mousetouchpad'
              activation = 'ms-settings:activation'; datetime = 'ms-settings:dateandtime'; language = 'ms-settings:regionlanguage'; defaultapps = 'ms-settings:defaultapps'; notif = 'ms-settings:notifications'
              taskbar = 'ms-settings:taskbar'; defender = 'windowsdefender:'; winver = 'winver.exe'; diskmgmt = 'diskmgmt.msc'; sysdm = 'sysdm.cpl'; cleanmgr = 'cleanmgr.exe'; services = 'services.msc'; eventvwr = 'eventvwr.msc'; msinfo = 'msinfo32.exe' }
    try {
        if ($map.ContainsKey($what)) {
            $t = $map[$what]
            if ($t -like 'ms-settings:*' -or $t -like 'windowsdefender:*') {
                # explorer.exe надёжно открывает ms-settings: даже когда Start-Process молчит
                try { Start-Process -FilePath 'explorer.exe' -ArgumentList $t -ErrorAction Stop; return $true } catch { }
                try { Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'start', '""', $t) -WindowStyle Hidden -ErrorAction Stop; return $true } catch { }
                return $false
            }
            Start-Process $t; return $true
        }
        if ($what -eq 'nvcp') {
            # панель NVIDIA: ищем её в меню «Пуск» по имени (настоящий идентификатор магазинной версии у разных сборок отличается),
            # затем классический nvcplui.exe, затем приложение NVIDIA
            $ids = @()
            try { $ids = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA Control Panel|Панель управления NVIDIA' } | Select-Object -ExpandProperty AppID) } catch { }
            foreach ($id in ($ids | Select-Object -First 2)) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $id) -ErrorAction Stop; return $true } catch { } }
            foreach ($pp in @("$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe", "${env:ProgramFiles(x86)}\NVIDIA Corporation\Control Panel Client\nvcplui.exe")) { if (Test-Path -LiteralPath $pp) { Start-Process $pp; return $true } }
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIACorp.NVIDIAControlPanel' -ErrorAction Stop; Start-Sleep -Milliseconds 900; if (Get-Process nvcplui -ErrorAction SilentlyContinue) { return $true } } catch { }
            $na = @(); try { $na = @(Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match '^NVIDIA app$|^NVIDIA App$' } | Select-Object -ExpandProperty AppID) } catch { }
            foreach ($id in ($na | Select-Object -First 1)) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $id) -ErrorAction Stop; return $true } catch { } }
            return $false
        }
        if ($what -eq 'router') {
            $gw = [string]$script:Gateway
            if ($gw -match '^(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$') { Start-Process ('http://' + $gw + '/'); return $true }
            return $false
        }
        if ($what -eq 'device') {
            # свойства конкретного устройства: в rundll32 уходит только InstanceId, найденный среди реальных устройств
            $nm = [string]$arg; $iid = $null
            if ($nm -match '\\') {
                $c = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPDeviceID -eq $nm }) | Select-Object -First 1
                if ($c) { $iid = [string]$c.PNPDeviceID } else { $c = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $nm }) | Select-Object -First 1; if ($c) { $iid = [string]$c.DeviceID } }
            } elseif ($nm) {
                $c = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceName -eq $nm -and $_.DeviceID }) | Select-Object -First 1
                if ($c) { $iid = [string]$c.DeviceID }
                if (-not $iid) { $c = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $nm }) | Select-Object -First 1; if ($c) { $iid = [string]$c.PNPDeviceID } }
            }
            if ($iid) { Start-Process 'rundll32.exe' -ArgumentList @('devmgr.dll,DeviceProperties_RunDLL', ('/DeviceID ' + $iid)); return $true }
            Start-Process 'devmgmt.msc'; return $false
        }
        if ($what -eq 'adapter') {
            # открываем свойства именно этого адаптера: имя сверяем со списком настоящих адаптеров
            $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -eq [string]$arg -or $_.Name -eq [string]$arg }) | Select-Object -First 1
            if (-not $ad) { $ad = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|TAP-|Wintun|Hyper-V|Bluetooth|Loopback|VPN|WAN Miniport|vEthernet|VMware|VirtualBox|Npcap' }) | Select-Object -First 1 }
            if ($ad -and $ad.PnPDeviceID) { Start-Process 'rundll32.exe' -ArgumentList @('devmgr.dll,DeviceProperties_RunDLL', ('/DeviceID ' + $ad.PnPDeviceID)); return $true }
            Start-Process 'devmgmt.msc'; return $true
        }
    } catch { }
    return $false
}

# ---- фоновые программы с оверлеем или записью экрана (только читаем список процессов) ----
$script:OverlayKnown = @(
    @{ p = 'Discord'; n = 'Discord'; w = 'Оверлей Discord и трансляция экрана могут добавлять нагрузку и задержку. Оверлей отключается в настройках Discord → Игровой оверлей.' },
    @{ p = 'obs64'; n = 'OBS Studio'; w = 'Запись или трансляция сама по себе нагружает процессор и видеокарту. Закройте, если сейчас не записываете.' },
    @{ p = 'obs32'; n = 'OBS Studio'; w = 'Запись или трансляция сама по себе нагружает процессор и видеокарту. Закройте, если сейчас не записываете.' },
    @{ p = 'Overwolf'; n = 'Overwolf'; w = 'Платформа игровых надстроек с оверлеем. Если не нужна, закройте.' },
    @{ p = 'NVIDIA Overlay'; n = 'Оверлей NVIDIA'; w = 'Игровой оверлей и фоновая запись NVIDIA (ShadowPlay). Отключается в приложении NVIDIA → Настройки → Игровой оверлей.' },
    @{ p = 'NVIDIA Share'; n = 'NVIDIA Share'; w = 'Часть оверлея NVIDIA с фоновой записью. Отключается в приложении NVIDIA.' },
    @{ p = 'MedalClient'; n = 'Medal'; w = 'Фоновая запись клипов. Закройте, если не нужна.' },
    @{ p = 'Medal'; n = 'Medal'; w = 'Фоновая запись клипов. Закройте, если не нужна.' },
    @{ p = 'GameBar'; n = 'Xbox Game Bar'; w = 'Оверлей Windows. Можно отключить в Параметры → Игры → Xbox Game Bar.' }
)
function Get-OverlayApps {
    if ($script:MockMode) { return @([ordered]@{ name = 'Discord'; what = $script:OverlayKnown[0].w }, [ordered]@{ name = 'OBS Studio'; what = $script:OverlayKnown[1].w }) }
    $out = @(); $seen = @{}
    try {
        $names = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })
        foreach ($k in $script:OverlayKnown) {
            if ($names -contains $k.p -and -not $seen.ContainsKey($k.n)) { $seen[$k.n] = 1; $out += [ordered]@{ name = $k.n; what = $k.w } }
        }
    } catch { }
    return @($out)
}
